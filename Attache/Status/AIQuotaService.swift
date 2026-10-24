//
//  AIQuotaService.swift
//  Attache
//

import AIUsageKit
import AppKit
import Foundation

/// Polls account-wide subscription quotas (Claude, Gemini / Antigravity, Grok)
/// for the sidebar footer deck via `AIUsageKit`.
///
/// Cross-process coordination is handled inside `AIUsageKit`:
/// - On `start()`, `AIUsage.cachedAll()` reads `~/Library/Caches/AIUsageKit/v1/<provider>.json`
///   synchronously (0 ms) so the first frame of the sidebar already draws the bars.
/// - `AIUsage.observeUpdates` listens for `DistributedNotificationCenter` broadcasts
///   whenever another app (such as `DockSidecar` or the `aiusage` CLI) refreshes a
///   provider, updating the rail immediately and pushing this app's next poll out.
/// - Every 5 minutes (`refreshInterval = 300`), `refreshNow()` requests fresh snapshots
///   with `maxAge = 240`. Under `AIUsageKit`'s per-provider `flock`, at most one
///   process on the Mac spawns the underlying CLI.
/// - Sleep and screen lock pause polling and trigger an immediate check on wake/unlock.
@MainActor
final class AIQuotaService {
    var onChange: (() -> Void)?

    private(set) var claudeUsage: AccountUsage?
    private(set) var geminiUsage: AccountUsage?
    private(set) var grokUsage: AccountUsage?

    private var timer: Timer?
    private var inFlight = false
    private var paused = false
    private var isLockedOrAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var crossProcessObserver: (any NSObjectProtocol)?

    private let refreshInterval: TimeInterval = 300
    private let cacheMaxAge: TimeInterval = 240

    func start() {
        registerPowerAndLockNotifications()

        // 1. Seed synchronously (0 ms) from the shared cross-process cache on disk.
        let cached = AIUsage.cachedAll([.claude, .antigravity, .grok])
        var seeded = false
        for (provider, usage) in cached {
            if apply(usage, for: provider) {
                seeded = true
            }
        }
        if seeded {
            onChange?()
        }

        // 2. Subscribe to cross-process updates so when DockSidecar or another tool
        // refreshes any provider, Attaché updates its gauges immediately.
        if crossProcessObserver == nil {
            crossProcessObserver = AIUsage.observeUpdates(for: [.claude, .antigravity, .grok]) { [weak self] provider, usage in
                guard let self else { return }
                if self.apply(usage, for: provider) {
                    self.onChange?()
                }
            }
        }

        // 3. Kick off a coordinated background check (fast-paths if cache is < 240s old).
        refreshNow()

        guard timer == nil else { return }
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        unregisterPowerAndLockNotifications()
        if let obs = crossProcessObserver {
            AIUsage.removeObserver(obs)
            crossProcessObserver = nil
        }
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    func setPaused(_ value: Bool) {
        let wasPaused = paused
        paused = value
        if wasPaused, !value, !isLockedOrAsleep {
            refreshNow()
        }
    }

    private func setLockedOrAsleep(_ value: Bool) {
        guard isLockedOrAsleep != value else { return }
        isLockedOrAsleep = value
        if !value, !paused {
            refreshNow()
        }
    }

    func refreshNow() {
        guard !paused, !isLockedOrAsleep, !inFlight else { return }
        inFlight = true
        let maxAge = cacheMaxAge
        Task {
            let results = await AIUsage.fetchAll([.claude, .antigravity, .grok], maxAge: maxAge)
            self.inFlight = false
            var changed = false
            for (provider, result) in results {
                if case let .success(usage) = result {
                    if self.apply(usage, for: provider) {
                        changed = true
                    }
                }
            }
            if changed {
                self.onChange?()
            }
        }
    }

    /// Maps a `ProviderUsage` from `AIUsageKit` into Attaché's `AccountUsage` and merges it.
    /// - Returns: `true` if the stored `AccountUsage` for that provider changed.
    @discardableResult
    private func apply(_ providerUsage: ProviderUsage, for provider: AIProvider) -> Bool {
        guard let converted = Self.toAccountUsage(providerUsage) else { return false }
        switch provider {
        case .claude:
            let merged = AccountUsage.merged(claudeUsage, converted) ?? converted
            guard merged != claudeUsage else { return false }
            claudeUsage = merged
            return true
        case .antigravity:
            let merged = AccountUsage.merged(geminiUsage, converted) ?? converted
            guard merged != geminiUsage else { return false }
            geminiUsage = merged
            return true
        case .grok:
            let merged = AccountUsage.merged(grokUsage, converted) ?? converted
            guard merged != grokUsage else { return false }
            grokUsage = merged
            return true
        }
    }

    // MARK: - Mapping ProviderUsage -> AccountUsage

    nonisolated static func toAccountUsage(_ usage: ProviderUsage, now: Date = Date()) -> AccountUsage? {
        func makeWindow(_ w: UsageWindow, defaultLength: TimeInterval) -> AccountUsage.Window? {
            guard let pct = w.usedPercent, pct.isFinite,
                  let resetsAt = w.resetsAt, resetsAt > now
            else { return nil }
            let length = (w.windowSeconds ?? defaultLength) > 0 ? (w.windowSeconds ?? defaultLength) : defaultLength
            return AccountUsage.Window(
                usedPercent: max(0, Int(pct.rounded())),
                resetsAt: resetsAt,
                length: length
            )
        }

        var out = AccountUsage()
        switch usage.provider {
        case .claude:
            for w in usage.windows {
                if w.id == "claude.session" || (w.kind == .session && out.fiveHour == nil) {
                    out.fiveHour = makeWindow(w, defaultLength: AccountUsage.fiveHourLength)
                } else if w.id == "claude.weekly" || (w.kind == .weekly && w.group == nil && out.sevenDay == nil) {
                    out.sevenDay = makeWindow(w, defaultLength: AccountUsage.sevenDayLength)
                }
            }

        case .antigravity:
            for w in usage.windows {
                switch w.id {
                case "antigravity.gemini-5h":
                    out.fiveHour = makeWindow(w, defaultLength: AccountUsage.fiveHourLength)
                case "antigravity.gemini-weekly":
                    out.sevenDay = makeWindow(w, defaultLength: AccountUsage.sevenDayLength)
                case "antigravity.3p-5h":
                    out.threePFiveHour = makeWindow(w, defaultLength: AccountUsage.fiveHourLength)
                case "antigravity.3p-weekly":
                    out.threePSevenDay = makeWindow(w, defaultLength: AccountUsage.sevenDayLength)
                default:
                    if w.id.contains("argon") || (w.group?.lowercased().contains("argon") == true) {
                        out.argonSevenDay = makeWindow(w, defaultLength: AccountUsage.sevenDayLength)
                    }
                }
            }

        case .grok:
            for w in usage.windows {
                if w.id == "grok.weekly" || w.kind == .weekly {
                    out.sevenDay = makeWindow(w, defaultLength: AccountUsage.sevenDayLength)
                } else if w.kind == .session {
                    out.fiveHour = makeWindow(w, defaultLength: AccountUsage.fiveHourLength)
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Power & Lock Notifications

    private func registerPowerAndLockNotifications() {
        guard observers.isEmpty else { return }
        let wsCenter = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()

        let sleepNotifs: [(NotificationCenter, NSNotification.Name)] = [
            (wsCenter, NSWorkspace.willSleepNotification),
            (wsCenter, NSWorkspace.screensDidSleepNotification),
            (distCenter, NSNotification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in sleepNotifs {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setLockedOrAsleep(true)
                }
            }
            observers.append(obs)
        }

        let wakeNotifs: [(NotificationCenter, NSNotification.Name)] = [
            (wsCenter, NSWorkspace.didWakeNotification),
            (wsCenter, NSWorkspace.screensDidWakeNotification),
            (distCenter, NSNotification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in wakeNotifs {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setLockedOrAsleep(false)
                }
            }
            observers.append(obs)
        }
    }

    private func unregisterPowerAndLockNotifications() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()
        for obs in observers {
            wsCenter.removeObserver(obs)
            distCenter.removeObserver(obs)
        }
        observers.removeAll()
    }
}
