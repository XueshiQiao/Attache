//
//  GeminiQuotaService.swift
//  Attache
//

import AppKit
import Foundation

/// Fetches account-wide Gemini / Antigravity rate-limit windows independently
/// of whether an Antigravity (`agy`) session is currently running in tmux.
///
/// Sources are tried in order on a background queue:
/// 1. `/tmp/agy_statusline_input.json` when modified recently (zero process or
///    network cost while an `agy` session is actively running).
/// 2. `agy --output-format json -p /usage` when the `agy` binary is present on
///    disk. This runs locally in printmode without invoking any LLM inference,
///    without consuming model tokens/quota, and without generating `.jsonl`
///    transcripts. Returns all 5 buckets: `gemini-5h`, `gemini-weekly`,
///    `3p-5h`, `3p-weekly`, and `gemini-argon-wtu-weekly`.
///
/// Automatically pauses when the screen is locked, display sleeps, or the system
/// enters sleep, and refreshes immediately upon unlock / wake.
@MainActor
final class GeminiQuotaService {
    var onChange: ((AccountUsage?) -> Void)?

    private(set) var currentUsage: AccountUsage?
    private var timer: Timer?
    private var inFlight = false
    private var paused = false
    private var isLockedOrAsleep = false
    private var observers: [NSObjectProtocol] = []
    private let refreshInterval: TimeInterval = 90

    func start() {
        registerPowerAndLockNotifications()
        // Seed immediately from a recent status-line snapshot on disk if one
        // exists, so the first frame of the sidebar already has numbers while
        // the background refresh runs.
        if let cached = Self.readStatusLineSnapshot(maxAge: 86_400) {
            currentUsage = cached
            onChange?(cached)
        }
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

    func refreshNow() {
        guard !paused, !isLockedOrAsleep, !inFlight else { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fetched = Self.fetchQuotaBlocking()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let fetched else { return }
                let merged = AccountUsage.merged(self.currentUsage, fetched) ?? fetched
                if merged != self.currentUsage {
                    self.currentUsage = merged
                    self.onChange?(merged)
                }
            }
        }
    }

    // MARK: - Background Fetching

    private nonisolated static func fetchQuotaBlocking() -> AccountUsage? {
        // The status-line file is written by every agy render and costs
        // nothing to read, so it is trusted for longer than a poll interval.
        let statusLine = readStatusLineSnapshot(maxAge: 600)
        if let statusLine, readStatusLineSnapshot(maxAge: 120) != nil {
            return statusLine
        }
        // `agy --output-format json -p /usage` carries all 5 quota buckets
        // (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, and
        // `gemini-argon-wtu-weekly`). It executes purely locally inside
        // `agy` CLI's printmode without invoking any LLM inference, without
        // consuming token quota, and without generating `.jsonl` transcript logs.
        if let fromCLI = fetchViaAgyCLI() {
            return AccountUsage.merged(statusLine, fromCLI)
        }
        return statusLine ?? readStatusLineSnapshot(maxAge: 86_400)
    }

    private nonisolated static func readStatusLineSnapshot(maxAge: TimeInterval) -> AccountUsage? {
        let path = "/tmp/agy_statusline_input.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) <= maxAge,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return AccountUsage.parseGeminiQuotaPayload(data)
    }

    private nonisolated static func fetchViaAgyCLI() -> AccountUsage? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--output-format", "json", "-p", "/usage"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Measured 2026-10-19: `agy -p /usage` takes ~7.8s. An 8s deadline
        // killed it most of the time and silently fell back to a source
        // without the Argon bucket.
        let deadline = Date().addingTimeInterval(25.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return AccountUsage.parseGeminiQuotaPayload(data)
    }
}

