//
//  GrokQuotaService.swift
//  Attache
//

import AppKit
import Foundation

/// Polls the Grok account's weekly allowance for the rail.
///
/// Independent of whether a `grok` session is running in tmux. The first
/// paint reads the credits line Grok already wrote; the timer then asks the
/// billing endpoint directly, so the number moves while this app is the only
/// thing awake. Sleep and a locked screen pause it, the same way the Gemini
/// poll does — a laptop in a bag should not keep the request going.
@MainActor
final class GrokQuotaService {
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
        if let cached = GrokQuota.loggedUsage() {
            currentUsage = cached
            onChange?(cached)
        }
        refreshNow()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        unregisterPowerAndLockNotifications()
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    private func registerPowerAndLockNotifications() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sleep: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in sleep {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setLockedOrAsleep(true) }
            })
        }
        let wake: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in wake {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setLockedOrAsleep(false) }
            })
        }
    }

    private func unregisterPowerAndLockNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func setLockedOrAsleep(_ value: Bool) {
        guard isLockedOrAsleep != value else { return }
        isLockedOrAsleep = value
        if !value, !paused { refreshNow() }
    }

    private func refreshNow() {
        guard !paused, !isLockedOrAsleep, !inFlight else { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fetched = GrokQuota.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let fetched else { return }
                if fetched != self.currentUsage {
                    self.currentUsage = fetched
                    self.onChange?(fetched)
                }
            }
        }
    }
}
