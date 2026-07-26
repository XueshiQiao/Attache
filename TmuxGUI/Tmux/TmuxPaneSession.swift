//
//  TmuxPaneSession.swift
//  TmuxGUI
//

import Foundation
import GhosttyTerminal

/// Binds one tmux pane to one libghostty surface.
///
/// This is the whole idea of the project in about a hundred lines: libghostty's
/// `.inMemory` backend does not own a pty, it just asks for bytes and hands
/// back keystrokes, so tmux can sit underneath it. The three wires are
///
///   tmux `%output`   → `InMemoryTerminalSession.receive`   (render)
///   `write` callback → `send-keys -H`                      (typing)
///   `resize` callback → `refresh-client -C`                (geometry)
///
/// Everything above this class is ordinary AppKit; everything below it is
/// ordinary tmux. Neither side knows about the other.
final class TmuxPaneSession {
    let terminalSession: InMemoryTerminalSession
    let metrics = TmuxMetrics()

    /// Human-readable state for the window title, delivered on the main queue.
    var onStatusChange: ((String) -> Void)?

    private let sessionName: String
    private let client: TmuxControlClient
    private let stateLock = NSLock()
    private var watchedPane: String?
    private var latestViewport: InMemoryTerminalViewport?
    /// Set only while a throughput probe runs, so measurement can target a
    /// synthetic heartbeat pane without changing what the window shows.
    private var measuredPaneOverride: String?
    private var probeInFlight = false

    init(tmuxPath: String, sessionName: String) {
        self.sessionName = sessionName
        let client = TmuxControlClient(tmuxPath: tmuxPath, sessionName: sessionName)
        self.client = client

        // Captured weakly-by-box: the session owns the client, and these
        // closures are owned by the session, so a direct capture of `self`
        // would be a cycle. The client is safe to capture — it outlives every
        // callback and holds no reference back to the terminal session.
        var paneProvider: () -> String? = { nil }
        var viewportSink: (InMemoryTerminalViewport) -> Void = { _ in }

        terminalSession = InMemoryTerminalSession(
            write: { data in
                guard let pane = paneProvider() else { return }
                client.sendKeys(pane: pane, data: data)
            },
            resize: { viewport in
                viewportSink(viewport)
            }
        )

        paneProvider = { [weak self] in self?.currentPane }
        viewportSink = { [weak self] viewport in self?.viewportChanged(viewport) }

        client.onPaneOutput = { [weak self] pane, data in
            self?.paneProduced(output: data, from: pane)
        }
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        client.onExit = { [weak self] reason in
            self?.report("tmux 已断开" + (reason.map { "：\($0)" } ?? ""))
        }
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try client.start()
            report("正在连接 tmux session「\(sessionName)」…")
        } catch {
            report("启动 tmux 失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        client.stop()
    }

    // MARK: - Wiring

    private var currentPane: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return watchedPane
    }

    private func paneProduced(output: Data, from pane: String) {
        // Called on the reader queue — deliberately not hopped to main. This is
        // the hot path, and `receive` already serialises onto its own queue.
        stateLock.lock()
        let rendered = watchedPane
        let measured = measuredPaneOverride ?? watchedPane
        stateLock.unlock()

        metrics.record(pane: pane, watched: pane == measured, byteCount: output.count)
        guard pane == rendered else { return }
        terminalSession.receive(output)
    }

    private func viewportChanged(_ viewport: InMemoryTerminalViewport) {
        stateLock.lock()
        latestViewport = viewport
        let havePane = watchedPane != nil
        stateLock.unlock()

        // tmux sizes a session's windows from its clients, so this is what
        // stops every window sitting at `default-size` 80x24. Holding it until
        // a pane is resolved avoids resizing the user's session before we even
        // know we can attach.
        guard havePane else { return }
        client.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
    }

    private func handle(_ notification: TmuxNotification) {
        switch notification {
        case .sessionChanged:
            resolveActivePane(initialPaint: true)

        case .other(let verb, _)
            where verb == "%session-window-changed" || verb == "%window-pane-changed":
            // Switching window or pane inside tmux — from any client, including
            // a plain terminal elsewhere — should move this view with it. This
            // is the bidirectional sync the whole design rests on.
            resolveActivePane(initialPaint: true)

        case .windowRenamed(_, let name):
            report("窗口改名为「\(name)」")

        case .paused(let pane):
            // tmux only pauses a pane when the pause-after flag is set, which
            // this spike does not set. Seeing one means output was dropped.
            report("⚠️ tmux 暂停了窗格 \(pane)（输出积压）")

        default:
            break
        }
    }

    /// Ask tmux which pane is active, then point this surface at it.
    private func resolveActivePane(initialPaint: Bool) {
        // `=name:` is exact session match plus current-window, current-pane.
        // Verified against tmux 3.6a: `-t '=name'` without the colon does not
        // resolve as a pane target and returns empty.
        client.run("display-message -p -t '=\(sessionName):' '#{pane_id}'") { [weak self] lines, failed in
            guard let self else { return }
            guard !failed, let pane = lines.first?.trimmingCharacters(in: .whitespaces), !pane.isEmpty else {
                self.report("找不到 session「\(self.sessionName)」的活跃窗格")
                return
            }

            self.stateLock.lock()
            let changed = self.watchedPane != pane
            self.watchedPane = pane
            let viewport = self.latestViewport
            self.stateLock.unlock()

            guard changed else { return }
            if let viewport {
                self.client.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
            if initialPaint { self.paintInitialContent(of: pane) }
            self.describe(pane: pane)
        }
    }

    /// tmux does not replay a pane's screen when a client attaches, so without
    /// this the surface stays blank until the program inside happens to write.
    private func paintInitialContent(of pane: String) {
        client.run("capture-pane -p -e -t \(pane)") { [weak self] lines, failed in
            guard let self, !failed else { return }
            // Home the cursor and clear first, otherwise the snapshot lands on
            // top of whatever the surface already showed.
            var payload = "\u{1b}[H\u{1b}[2J"
            payload += lines.joined(separator: "\r\n")
            self.terminalSession.receive(payload)
        }
    }

    private func describe(pane: String) {
        let format = "#{window_index}:#{window_name} · #{window_panes} 个窗格 · #{pane_width}x#{pane_height}"
        client.run("display-message -p -t \(pane) '\(format)'") { [weak self] lines, failed in
            guard let self, !failed, let text = lines.first else { return }
            self.report("\(self.sessionName) → \(text) · \(pane)")
        }
    }

    // MARK: - Throughput probe

    /// Measure whether one busy pane starves the others.
    ///
    /// Control mode multiplexes every pane in the session onto one pipe, so the
    /// risk is not raw bandwidth — it is that an AI agent redrawing at full
    /// speed in window 3 makes window 7 feel laggy. Byte counters cannot see
    /// that. This runs an A/B instead:
    ///
    ///   A — a synthetic pane printing one byte every 50ms, alone.
    ///   B — the same pane, while a second pane floods the pipe.
    ///
    /// If the arrival gaps in B stay near 50ms the design holds; if they blow
    /// up, that is the number that decides whether this project is worth
    /// building. Both helper windows are created detached and killed
    /// afterwards, so nothing the user is looking at is touched.
    func runThroughputProbe(phaseSeconds: TimeInterval = 8, completion: @escaping (String) -> Void) {
        stateLock.lock()
        guard !probeInFlight else {
            stateLock.unlock()
            completion("已经有一轮压测在跑了。")
            return
        }
        probeInFlight = true
        stateLock.unlock()

        report("压测中：阶段 A（只有心跳）…")
        let heartbeat = "while :; do printf .; sleep 0.05; done"

        client.run("new-window -d -P -F '#{window_id} #{pane_id}' -t '=\(sessionName):' -n tmuxgui-probe '\(heartbeat)'") { [weak self] lines, failed in
            guard let self else { return }
            guard !failed, let ids = lines.first?.split(separator: " "), ids.count == 2 else {
                self.finishProbe(completion: completion, text: "建心跳窗口失败：\(lines.joined(separator: " "))")
                return
            }
            let probeWindow = String(ids[0])
            let probePane = String(ids[1])

            self.stateLock.lock()
            self.measuredPaneOverride = probePane
            self.stateLock.unlock()

            // Let the shell in the new pane finish starting before counting;
            // its startup output would otherwise land in the baseline.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                self.metrics.reset()
                DispatchQueue.global().asyncAfter(deadline: .now() + phaseSeconds) {
                    let baseline = self.metrics.snapshot()
                    self.runFloodPhase(
                        phaseSeconds: phaseSeconds,
                        probeWindow: probeWindow,
                        baseline: baseline,
                        completion: completion
                    )
                }
            }
        }
    }

    private func runFloodPhase(
        phaseSeconds: TimeInterval,
        probeWindow: String,
        baseline: TmuxMetrics.Snapshot,
        completion: @escaping (String) -> Void
    ) {
        report("压测中：阶段 B（心跳 + 另一个窗格全速刷屏）…")
        let filler = String(repeating: "0123456789ABCDEF", count: 4)

        client.run("new-window -d -P -F '#{window_id}' -t '=\(sessionName):' -n tmuxgui-flood 'yes \(filler)'") { [weak self] lines, failed in
            guard let self else { return }
            guard !failed, let floodWindow = lines.first?.trimmingCharacters(in: .whitespaces), !floodWindow.isEmpty else {
                self.client.send("kill-window -t \(probeWindow)")
                self.finishProbe(completion: completion, text: "建刷屏窗口失败：\(lines.joined(separator: " "))")
                return
            }

            self.metrics.reset()
            DispatchQueue.global().asyncAfter(deadline: .now() + phaseSeconds) {
                let loaded = self.metrics.snapshot()
                self.client.send("kill-window -t \(floodWindow)")
                self.client.send("kill-window -t \(probeWindow)")
                self.finishProbe(
                    completion: completion,
                    text: Self.compare(baseline: baseline, loaded: loaded)
                )
            }
        }
    }

    private func finishProbe(completion: @escaping (String) -> Void, text: String) {
        stateLock.lock()
        measuredPaneOverride = nil
        probeInFlight = false
        stateLock.unlock()
        metrics.reset()
        resolveActivePane(initialPaint: false)
        DispatchQueue.main.async { completion(text) }
    }

    private static func compare(baseline: TmuxMetrics.Snapshot, loaded: TmuxMetrics.Snapshot) -> String {
        let ms = { (value: TimeInterval) in String(format: "%.0f", value * 1000) }
        // The heartbeat ticks every 50ms by construction, so the baseline gap
        // is the control and any growth under load is pure queueing delay.
        let degradation = baseline.p99Gap > 0 ? loaded.p99Gap / baseline.p99Gap : 0

        return """
        A · 只有心跳（每 50ms 一个字节）
            到达间隔  中位 \(ms(baseline.medianGap))ms · p99 \(ms(baseline.p99Gap))ms · 最差 \(ms(baseline.worstGap))ms
            心跳样本  \(baseline.watchedChunks) 个
            同会话其它窗格  \(baseline.otherBytes) 字节

        B · 心跳 + 另一个窗格全速刷屏
            到达间隔  中位 \(ms(loaded.medianGap))ms · p99 \(ms(loaded.p99Gap))ms · 最差 \(ms(loaded.worstGap))ms
            心跳样本  \(loaded.watchedChunks) 个
            刷屏窗格产出  \(loaded.otherBytes) 字节（\(String(format: "%.1f", Double(loaded.otherBytes) / max(loaded.elapsed, 0.001) / 1_048_576)) MB/s）

        结论
            p99 卡顿从 \(ms(baseline.p99Gap))ms 变成 \(ms(loaded.p99Gap))ms，\
        \(degradation > 0 ? String(format: "劣化 %.1f 倍", degradation) : "无法比较")。
            心跳本该恒定 50ms —— B 里偏离多少，就是刷屏挤占管道造成的延迟。
        """
    }

    private func report(_ status: String) {
        // tmux-sourced text (window names above all) carries live escape
        // sequences; a window title is not a terminal.
        let clean = TmuxText.plain(status)
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(clean)
        }
    }
}
