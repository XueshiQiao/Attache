//
//  DiagnosticsCenter.swift
//  Attache
//

import Foundation

/// The app checking that what it asked for actually happened.
///
/// Every silent failure of 2026-07-29 had the same shape: a command went out,
/// the confirmation never came, and nothing anywhere said so. This is the
/// other half — fed by three one-line taps (`TmuxLog.command()`, the
/// `%begin`/`%end` handler, `notifyModelChanged()`) plus `ActivationProbe`'s
/// self-subscription, it derives what each command entitles the app to
/// observe and raises the alarm when the observation never arrives.
///
/// **Write-only, and that is a load-bearing property, not a style choice.**
/// This type may write logs, snapshots and notices. It must never send a
/// repair command, retry anything, or hand a value back to the code it
/// watches — the moment the observer becomes a participant, a false positive
/// turns into a real fault, and it stops being safe to leave on. The one
/// exception is the read-only truth query a snapshot performs, which asks
/// tmux questions and changes nothing.
///
/// Everything here runs on the main queue. The two taps that fire elsewhere
/// hop; the hop is what makes expectation baselines race-free, because the
/// hop is enqueued before the command reaches tmux, so it always runs before
/// the main-queue work its reply produces.
final class DiagnosticsCenter {
    static let shared = DiagnosticsCenter()

    /// Where notices go — `AppDelegate` points this at `NoticeCenter`. A
    /// closure rather than the type, so this file stays free of AppKit and
    /// callable from `Attache/Tmux/`.
    var noticeSink: ((AppNotice) -> Void)?

    // MARK: - State (main queue only)

    private struct WeakConnection {
        weak var value: TmuxSessionConnection?
    }

    private var connections = [WeakConnection]()

    private struct Pending {
        var expectation: CommandExpectation
        weak var connection: TmuxSessionConnection?
        var sessionLabel: String
        var sentAt: Date
        /// Set once the log tier has fired, which is also what arms the
        /// met-late resolution line.
        var unmetLogged = false
        var snapshotName: String?
    }

    private var pending = [Pending]()

    /// Per-connection liveness, keyed by session label. The one detector that
    /// still works when everything else goes quiet: on a deaf channel no
    /// expectation resolves, no notification arrives, and the only observable
    /// fact left is "commands go out and nothing at all comes back".
    private struct ChannelProbe {
        var firstUnansweredAt: Date?
        var unanswered = 0
        var reportedDeaf = false
    }

    private var probes = [String: ChannelProbe]()

    /// The last commands out and blocks in, oldest first — the `recent` array
    /// of every snapshot. Command text arrives already redacted by `TmuxLog`,
    /// so a `send-keys` payload cannot leak in through here.
    private var recent = [String]()
    private let recentCap = 200

    /// Activation, key-window and first-responder transitions, oldest first.
    /// Exists because the app once looked frozen for an hour while its only
    /// problem was not being the active application, and nothing had recorded
    /// that it ever was.
    private var activation = [String]()
    private let activationCap = 120

    private var sweepTimer: Timer?

    /// Deadline for the deaf-channel probe, and the sweep cadence under the
    /// tightest expectation deadline (300 ms): a sweep at 150 ms reports an
    /// unmet 300 ms expectation somewhere in 300–450 ms, and the line prints
    /// the real elapsed time, so the resolution costs precision in the
    /// firing moment and none in the record.
    private let deafAfter: TimeInterval = 5
    private let sweepInterval: TimeInterval = 0.15

    private let ringStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        onMain {
            AnomalyLog.prune()
            let timer = Timer(timeInterval: self.sweepInterval, repeats: true) { [weak self] _ in
                self?.sweep()
            }
            timer.tolerance = 0.05
            // `.common`, or the sweep pauses while a menu is open — and a
            // stuck state discovered through a menu is not hypothetical here.
            RunLoop.main.add(timer, forMode: .common)
            self.sweepTimer = timer
            TmuxLog.lifecycle("diagnostics started — sweep every \(Int(self.sweepInterval * 1000))ms")
        }
    }

    /// When probes for vanished connections were last swept out — see `sweep`.
    private var lastProbePrune = Date.distantPast

    // MARK: - Taps

    func register(_ connection: TmuxSessionConnection) {
        onMain {
            self.connections.removeAll { $0.value == nil }
            self.connections.append(WeakConnection(value: connection))
        }
    }

    /// From `TmuxLog.command()`, on whatever thread sent the command. The
    /// text is the redacted form; see `recent`.
    func commandSent(_ command: String, session label: String) {
        onMain {
            self.remember("→ [\(label)] \(command)")
            var probe = self.probes[label] ?? ChannelProbe()
            probe.unanswered += 1
            if probe.firstUnansweredAt == nil { probe.firstUnansweredAt = Date() }
            self.probes[label] = probe

            guard let connection = self.connection(labelled: label) else { return }
            guard let expectation = CommandExpectation.derive(
                from: command, facts: self.facts(of: connection)
            ) else { return }
            let entry = Pending(
                expectation: expectation, connection: connection,
                sessionLabel: label, sentAt: Date()
            )
            // A repeat of the same intent replaces its predecessor: five
            // clicks on one pane are one question, not five toasts.
            if let index = self.pending.firstIndex(where: {
                $0.sessionLabel == label && $0.expectation.dedupeKey == expectation.dedupeKey
            }) {
                self.pending[index] = entry
            } else {
                self.pending.append(entry)
            }
        }
    }

    /// From the `%end` handler, on the reader queue. Any block counts as
    /// liveness — a block tmux produced on its own behalf still proves the
    /// channel carries bytes in this direction.
    func replyBlockEnded(
        session label: String, number: Int, isCommandReply: Bool, failed: Bool, lines: Int
    ) {
        onMain {
            self.remember(
                "← [\(label)] block #\(number) ours=\(isCommandReply ? 1 : 0)"
                    + " failed=\(failed ? 1 : 0) lines=\(lines)"
            )
            guard var probe = self.probes[label] else { return }
            if probe.reportedDeaf, let since = probe.firstUnansweredAt {
                let line = "channel answering again after \(self.milliseconds(since: since))"
                AnomalyLog.record(kind: "CHANNEL", session: label, line: line, detail: "(recovered)")
                TmuxLog.lifecycle("ANOMALY resolved — \(line)", session: label)
            }
            probe.firstUnansweredAt = nil
            probe.unanswered = 0
            probe.reportedDeaf = false
            self.probes[label] = probe
        }
    }

    /// From `notifyModelChanged()`, already on the main queue. The moment an
    /// expectation can be answered, because the mirror is what it is checked
    /// against.
    func modelChanged(_ connection: TmuxSessionConnection) {
        onMain {
            self.evaluate(connection: connection)
        }
    }

    /// From `ActivationProbe`, on the main queue.
    func recordActivation(_ line: String) {
        onMain {
            self.activation.append("[\(self.ringStamp.string(from: Date()))] \(line)")
            if self.activation.count > self.activationCap {
                self.activation.removeFirst(self.activation.count - self.activationCap)
            }
        }
    }

    /// Any producer, any thread. This is the general door — the pane-paused
    /// notification uses it today, and it is deliberately one line to use so
    /// the next producer does too.
    func notice(_ notice: AppNotice) {
        onMain {
            self.noticeSink?(notice)
        }
    }

    // MARK: - Evaluation

    private func evaluate(connection: TmuxSessionConnection) {
        guard pending.contains(where: { $0.connection === connection }) else { return }
        let facts = facts(of: connection)
        var kept = [Pending]()
        for entry in pending {
            guard entry.connection === connection else {
                kept.append(entry)
                continue
            }
            if entry.expectation.isMet(facts) == true {
                resolve(entry)
            } else {
                kept.append(entry)
            }
        }
        pending = kept
    }

    /// An expectation that was reported unmet and then met anyway is the
    /// difference between a slow round trip and a stall, and the log should
    /// say which one it was.
    private func resolve(_ entry: Pending) {
        guard entry.unmetLogged else { return }
        let line = "\(entry.expectation.command) met after \(milliseconds(since: entry.sentAt))"
        AnomalyLog.record(
            kind: "EXPECT", session: entry.sessionLabel, line: line,
            detail: "(slow round trip, not a stall; was reported unmet"
                + (entry.snapshotName.map { " — snapshot=\($0)" } ?? "") + ")"
        )
        TmuxLog.lifecycle("ANOMALY resolved — \(line)", session: entry.sessionLabel)
    }

    private func sweep() {
        let now = Date()

        // Probes must die with their connections, and the reason is sharper
        // than memory hygiene: probes are keyed by session *name*, so a session
        // killed mid-episode leaves `reportedDeaf` latched — and a future
        // session that happens to take the same name would inherit it and
        // never be able to report. Observed 2026-07-29 when the verification
        // session was killed while its channel was deliberately frozen.
        if now.timeIntervalSince(lastProbePrune) > 5 {
            lastProbePrune = now
            let liveLabels = Set(connections.compactMap { $0.value?.sessionName })
            probes = probes.filter { liveLabels.contains($0.key) }
        }

        var kept = [Pending]()
        for var entry in pending {
            guard let connection = entry.connection else { continue }
            let facts = facts(of: connection)
            if entry.expectation.isMet(facts) == true {
                resolve(entry)
                continue
            }
            let elapsed = now.timeIntervalSince(entry.sentAt)
            if !entry.unmetLogged, elapsed >= entry.expectation.logAfter {
                entry.unmetLogged = true
                entry.snapshotName = reportUnmet(entry, facts: facts, connection: connection)
            }
            if elapsed >= entry.expectation.toastAfter {
                notice(AppNotice(
                    severity: .warning,
                    title: entry.expectation.title,
                    body: "Asked tmux for \(entry.expectation.subject). "
                        + "No confirmation after \(seconds(entry.expectation.toastAfter)).",
                    session: entry.sessionLabel
                ))
                // Retired at the toast: the person has been told, the log and
                // snapshot exist, and keeping it would only re-toast.
                continue
            }
            kept.append(entry)
        }
        pending = kept

        for (label, var probe) in probes {
            guard !probe.reportedDeaf,
                  let since = probe.firstUnansweredAt,
                  now.timeIntervalSince(since) >= deafAfter
            else { continue }
            probe.reportedDeaf = true
            probes[label] = probe
            reportDeafChannel(label: label, probe: probe, since: since)
        }
    }

    // MARK: - Reporting

    /// One snapshot per *episode*, not per report.
    ///
    /// The real-world shape of a persistent fault is a flap: deaf → one reply
    /// lands → deaf again, every few seconds. Measured on 2026-07-29 with a
    /// `run-shell "sleep 12"` hook: five deaf reports in forty seconds. Each
    /// wrote a snapshot, and at that rate the 20-file cap evicts the *first*
    /// snapshot of the episode — the one holding the transition into the
    /// fault, which is the one the cap exists to protect. So repeats within
    /// the window reuse the original snapshot's name and are counted instead;
    /// the log line still fires every time, because a fault that is still
    /// happening deserves a line each time it re-proves itself. A fault that
    /// stays quiet for the whole window is a new episode and gets a fresh
    /// snapshot.
    private struct SnapshotEpisode {
        let name: String
        let firstAt: Date
        var lastAt: Date
        var repeats: Int
    }

    private var snapshotEpisodes = [String: SnapshotEpisode]()
    private let snapshotCooldown: TimeInterval = 60

    /// Whether this anomaly opens a new episode (write a snapshot under the
    /// returned name) or continues one (reuse the old name, skip the write).
    /// The suffix is ready-made for the log line either way.
    private func claimSnapshot(kind: String, session: String) -> (name: String, isFresh: Bool, suffix: String) {
        let key = "\(kind)|\(session)"
        let now = Date()
        if var episode = snapshotEpisodes[key],
           now.timeIntervalSince(episode.lastAt) < snapshotCooldown
        {
            episode.lastAt = now
            episode.repeats += 1
            snapshotEpisodes[key] = episode
            return (
                episode.name, false,
                " (repeat ×\(episode.repeats) of this episode — snapshot not rewritten)"
            )
        }
        let name = AnomalyLog.snapshotName(kind: kind)
        snapshotEpisodes[key] = SnapshotEpisode(name: name, firstAt: now, lastAt: now, repeats: 1)
        return (name, true, "")
    }

    private func reportUnmet(
        _ entry: Pending, facts: DiagnosticsFacts, connection: TmuxSessionConnection
    ) -> String {
        let claim = claimSnapshot(kind: entry.expectation.kind, session: entry.sessionLabel)
        let line = "\(entry.expectation.command) unmet after \(milliseconds(since: entry.sentAt))"
        let detail = "\(entry.expectation.unmetDetail(facts)) snapshot=\(claim.name)\(claim.suffix)"
        AnomalyLog.record(kind: "EXPECT", session: entry.sessionLabel, line: line, detail: detail)
        TmuxLog.lifecycle("ANOMALY — \(line) \(detail)", session: entry.sessionLabel)
        if claim.isFresh {
            writeSnapshot(named: claim.name, anomaly: "\(line) \(detail)", connection: connection)
        }
        return claim.name
    }

    private func reportDeafChannel(label: String, probe: ChannelProbe, since: Date) {
        let elapsed = Date().timeIntervalSince(since)
        let claim = claimSnapshot(kind: "deaf-channel", session: label)
        let line = "\(probe.unanswered) command(s) sent, no reply block for "
            + "\(seconds(elapsed))"
        let detail = "(channel presumed deaf) snapshot=\(claim.name)\(claim.suffix)"
        AnomalyLog.record(kind: "CHANNEL", session: label, line: line, detail: detail)
        TmuxLog.lifecycle("ANOMALY — \(line) \(detail)", session: label)
        if claim.isFresh {
            writeSnapshot(
                named: claim.name, anomaly: "\(line) \(detail)",
                connection: connection(labelled: label)
            )
        }
        notice(AppNotice(
            severity: .error,
            title: "tmux stopped answering",
            body: "Session \(label) · \(probe.unanswered) commands sent, "
                + "no reply for \(seconds(elapsed)).",
            session: label
        ))
        // Reporting is the whole job locally; over ssh the connection also
        // gets the chance to remake itself, because a dead mux channel never
        // heals on its own. The connection decides — it knows its transport.
        connection(labelled: label)?.channelWentDeaf()
    }

    // MARK: - Snapshots

    /// The scene at the moment of the anomaly: what tmux says, what the app
    /// believed, the recent wire traffic, and the activation history.
    ///
    /// The truth half goes through the same connection the anomaly is about,
    /// with a deadline — on a deaf channel the query never answers, and "the
    /// truth query itself went unanswered" is recorded as exactly that, which
    /// is the most incriminating fact a deaf-channel snapshot can hold.
    private func writeSnapshot(
        named name: String, anomaly: String, connection: TmuxSessionConnection?
    ) {
        var payload: [String: Any] = [
            "anomaly": anomaly,
            "recent": recent,
            "activation": activation,
        ]
        if let connection {
            let facts = facts(of: connection)
            payload["appModel"] = [
                "session": connection.sessionName,
                "activeWindow": facts.activeWindowID ?? "none",
                "windows": facts.windows.map { window in
                    [
                        "id": window.id,
                        "index": window.index,
                        "name": window.name,
                        "activePane": window.activePaneID,
                        "panes": window.paneIDs,
                        "savedLayout": window.savedLayout,
                        "visibleLayout": window.visibleLayout,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }

        guard let connection else {
            payload["tmuxTruth"] = "no connection to ask"
            DispatchQueue.global(qos: .utility).async {
                AnomalyLog.writeSnapshot(named: name, payload: payload)
            }
            return
        }
        connection.diagnosticsTruth(timeout: 2) { truth in
            payload["tmuxTruth"] = truth
            DispatchQueue.global(qos: .utility).async {
                AnomalyLog.writeSnapshot(named: name, payload: payload)
            }
        }
    }

    // MARK: - Helpers

    private func connection(labelled label: String) -> TmuxSessionConnection? {
        connections.first { $0.value?.sessionName == label }?.value
    }

    private func facts(of connection: TmuxSessionConnection) -> DiagnosticsFacts {
        DiagnosticsFacts(
            activeWindowID: connection.activeWindowID,
            windows: connection.windows.map { window in
                DiagnosticsWindowFacts(
                    id: window.id, index: window.index, name: window.name,
                    activePaneID: window.activePaneID, paneIDs: window.paneIDs,
                    savedLayout: window.savedLayoutText,
                    visibleLayout: window.visibleLayoutText
                )
            }
        )
    }

    private func remember(_ line: String) {
        recent.append("[\(ringStamp.string(from: Date()))] \(line)")
        if recent.count > recentCap { recent.removeFirst(recent.count - recentCap) }
    }

    private func milliseconds(since date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000))ms"
    }

    private func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", interval)
    }

    /// Main-queue confinement with ordering preserved: synchronous when
    /// already there — which keeps `modelChanged` in step with the model write
    /// that called it — and a FIFO hop otherwise, which is what guarantees a
    /// command's baseline is captured before its own reply can be processed.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
