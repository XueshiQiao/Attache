//
//  GitToolView.swift
//  Attache
//

import AppKit
import GhosttyTerminal

/// The rail's Git tool: lazygit — or whatever `git_tool_command` names —
/// running in a terminal this app owns.
///
/// **The process is the app's, not tmux's, and that is a boundary rather than
/// a shortcut.** This tool is part of the GUI, like the conversation beside
/// it; putting it in a tmux window would show it to every client attached from
/// an ordinary terminal and leave it behind in their session list when this
/// app quits. So the surface here runs its child directly, the way a plain
/// terminal window would, and tmux never hears about it.
///
/// **What it points at follows the window on screen.** The current window's
/// pane path resolves to a repository root — the *worktree* root, which for
/// this user's workflow of one agent per worktree is the repository that agent
/// is editing. The follow rule is deliberately lazy in both directions:
///
/// - The child starts the first time the tool is actually revealed, not when
///   the app launches.
/// - It restarts only when the *root* changes. Switching between windows that
///   sit in the same worktree keeps the running instance, cursor position and
///   all — a restart per window switch would flash for nothing.
/// - A root change that happens while the tool is hidden (other tab up, rail
///   collapsed) is noted and acted on at the next reveal. Nothing restarts
///   behind a tab nobody is looking at.
/// - A collapsed rail ends the child entirely — off screen is off duty, same
///   as the conversation's file watcher and the git reader's pause.
final class GitToolView: NSView {

    // MARK: - Header

    // The same band the conversation draws, in the same geometry, because the
    // two are the same rail wearing different tabs: 30pt of draggable window
    // chrome, an 11pt semibold title, a 10pt monospaced meta line.
    private let titleLabel = NSTextField(labelWithString: "Git")
    private let metaLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSBox()
    private let titleDragStrip = TitleDragStrip()
    private lazy var headerTrailing = titleLabel.superview!.trailingAnchor
        .constraint(equalTo: trailingAnchor, constant: -9)

    private let placeholderLabel = NSTextField(labelWithString: "")
    private let reopenButton = NSButton(title: "Open again", target: nil, action: nil)

    /// Status lines with nowhere of their own to go — "no such path" from a
    /// link click — are handed up, and `MainViewController` routes them to the
    /// current session's status line.
    var onStatus: ((String) -> Void)?

    // MARK: - What is being followed

    private var path: String?
    private var root: String?
    private var knownNotRepository = false
    private var summary: GitSummary?

    /// The root the running child was started in. `nil` means no child.
    private var runningRoot: String?
    /// The child ended on its own — `q`, or a crash — while sitting in this
    /// root. Held so the tool shows "exited" with a way back rather than
    /// auto-restarting: a child that dies instantly (bad flag in the setting,
    /// say) would otherwise respawn in a loop forever. A *different* root
    /// arriving clears it, because following the window is what was asked for.
    private var exitedRoot: String?

    /// Whether the rail as a whole is on screen. False tears the child down.
    var isRailVisible = false {
        didSet { if oldValue != isRailVisible { reconcile() } }
    }
    /// Whether this tab is the one showing. False keeps a running child alive
    /// but neither starts nor restarts one.
    var isRevealed = false {
        didSet {
            guard oldValue != isRevealed else { return }
            // A cached "not a repository" is never re-asked on its own — a
            // `git init` after the answer landed would leave this tool wrong
            // until relaunch. Re-asked once per reveal, which bounds the
            // extra work to one lookup per click (Codex review, 2026-08-03).
            if isRevealed, knownNotRepository, let path { onRevealRecheck?(path) }
            reconcile()
        }
    }

    /// Wired to `GitStatusService.reresolveIfNotRepository` — the service is
    /// the controller's; this view only says when looking again is worth it.
    var onRevealRecheck: ((String) -> Void)?

    private var terminalView: TmuxTerminalView?
    private var terminalController: TerminalController?
    private var delegateBox: DelegateBox?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Same answer as the conversation's, for the same reason: a content area
    /// that inherits "yes, drag the window" fights every gesture that starts
    /// in it. The strip across the top is the deliberate exception.
    override var mouseDownCanMoveWindow: Bool { false }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [titleLabel, metaLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        reopenButton.bezelStyle = .rounded
        reopenButton.controlSize = .small
        reopenButton.target = self
        reopenButton.action = #selector(reopenClicked)
        reopenButton.isHidden = true
        reopenButton.translatesAutoresizingMaskIntoConstraints = false

        // The terminal is inserted at the bottom of this pile when it exists:
        // on macOS 26 a drawing view's backing layer overhangs its frame
        // (CLAUDE.md), so the header has to be the later sibling to survive
        // the overlap.
        addSubview(titleDragStrip)
        addSubview(placeholderLabel)
        addSubview(reopenButton)
        addSubview(header)
        addSubview(headerSeparator)

        NSLayoutConstraint.activate([
            titleDragStrip.topAnchor.constraint(equalTo: topAnchor),
            titleDragStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleDragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleDragStrip.heightAnchor.constraint(equalToConstant: 30),

            header.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            headerTrailing,

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            reopenButton.topAnchor.constraint(equalTo: placeholderLabel.bottomAnchor, constant: 10),
            reopenButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        applyChromeTheme()
    }

    /// The rail's tool tabs sit at the right end of the header row; the title
    /// has to stop where they start. Mirrors the conversation's.
    func reserveHeaderSpace(_ width: CGFloat) {
        headerTrailing.constant = -(9 + width)
    }

    func applyChromeTheme() {
        let theme = ChromeTheme.current
        titleLabel.textColor = theme.faintText
        metaLabel.textColor = theme.faintText
        placeholderLabel.textColor = theme.faintText
    }

    // MARK: - Input

    /// The machine the followed window's repository is on. What the child
    /// spawn branches on: a local root gets lazygit as a local child, a
    /// remote one gets `ssh -t <host> -- lazygit -p <root>` — same view,
    /// same teardown, different machine doing the work.
    struct HostEnv {
        let id: String
        let name: String
        let isLocal: Bool
        let transport: TmuxTransport
        let helper: RemoteHelper?
        /// Per-host `git_tool_command` override, when configured.
        let gitToolCommand: String?
        /// The `%h`/`%p` template a ⌘-clicked remote path opens with.
        let remoteOpenCommand: String?
    }

    private var hostEnv: HostEnv?
    /// Which machine `runningRoot` is on: `/Users/joey/x` here and on the
    /// mini are different repositories with one name.
    private var runningHostID: String?
    /// Remote lazygit paths, probed once per host per run. `.some(nil)`
    /// means probed-and-missing — the placeholder case, not a retry.
    private var remoteProgramByHost = [String: String?]()
    private var remoteProbesInFlight = Set<String>()

    /// Everything the tool follows, in one call, from `refreshConversation` —
    /// which already runs on every window switch, path change and git-status
    /// change, so there is no schedule of this tool's own to keep.
    func update(
        host: HostEnv?, path: String?, root: String?,
        knownNotRepository: Bool, summary: GitSummary?
    ) {
        hostEnv = host
        self.path = path
        self.root = root
        self.knownNotRepository = knownNotRepository
        self.summary = summary
        reconcile()
    }

    // MARK: - The follow rule

    private func reconcile() {
        updateHeader()
        guard isRailVisible else {
            teardownChild()
            exitedRoot = nil
            return
        }
        guard isRevealed else { return }

        guard let path else {
            teardownChild()
            showPlaceholder("No window on screen.")
            return
        }
        if let root {
            if runningRoot == root, runningHostID == hostEnv?.id {
                // Already right — but possibly hidden behind the placeholder
                // a moment of "resolving…" put up. Window switches within one
                // worktree land here.
                showChild()
                return
            }
            if exitedRoot == root {
                showPlaceholder("\(programName) exited.", reopen: true)
                return
            }
            start(in: root)
        } else if knownNotRepository {
            teardownChild()
            showPlaceholder("Not inside a git repository.\n\(abbreviated(path))")
        } else if runningRoot == nil {
            // The root is still being resolved. If a child from the previous
            // root is running, it stays until the answer lands — flashing a
            // placeholder for a lookup that resolves in milliseconds would
            // blink on every window switch.
            showPlaceholder("")
        }
    }

    private func updateHeader() {
        if let root {
            var title = (root as NSString).lastPathComponent
            if let branch = summary?.branch {
                title += " · \(branch)"
            } else if let detached = summary?.detachedAt {
                title += " · \(detached)"
            }
            titleLabel.stringValue = title
            metaLabel.stringValue = abbreviated(root)
        } else {
            titleLabel.stringValue = "Git"
            metaLabel.stringValue = path.map(abbreviated) ?? ""
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The first word of the configured command, for messages — "lazygit
    /// exited", or whatever it was swapped for.
    private var programName: String {
        configuredCommand.split(separator: " ").first.map(String.init) ?? "lazygit"
    }

    /// The per-host override wins: the same person can run stock lazygit
    /// here and a pinned one on the machine that has it.
    private var configuredCommand: String {
        hostEnv?.gitToolCommand ?? AppSettings.gitToolCommand
    }

    // MARK: - The child

    private func start(in root: String) {
        teardownChild()
        exitedRoot = nil
        // A path is legal with almost any byte in it, and the generated
        // ghostty config is a line-oriented text format: a root carrying a
        // newline would end the `working-directory` line early and hand the
        // rest to the parser as fresh keys — `command = …` included. Refused
        // outright rather than escaped, because the parser documents no
        // escaping to lean on. Leading or trailing whitespace is refused for
        // the smaller version of the same failure: the parser trims it, and
        // lazygit would open somewhere that is not the root (Codex review,
        // 2026-08-03).
        guard root.rangeOfCharacter(from: .newlines) == nil,
              root == root.trimmingCharacters(in: .whitespaces)
        else {
            showPlaceholder(
                "This repository's path can't be handed to a terminal safely:\n"
                    + abbreviated(root)
            )
            return
        }
        let command: String
        let workingDirectory: String?
        if let env = hostEnv, !env.isLocal {
            // The root meets two shells on the way to the other machine —
            // quoting is total (`TransportCheck` executes it), and the
            // refusals above still hold because policy beats mechanism.
            switch remoteCommand(env: env, root: root) {
            case .command(let line):
                command = line
                // Local-only key: the path names a directory on the other
                // machine. lazygit's `-p` carries the target instead.
                workingDirectory = nil
            case .probing:
                showPlaceholder("Looking for \(programName) on \(env.name)…")
                return
            case .missing:
                showPlaceholder(
                    "Can't find \"\(programName)\" on \(env.name).\n"
                        + "Install it there, or set git_tool_command in this host's"
                        + " [[host]] block in ~/.config/attache.toml."
                )
                return
            }
        } else {
            guard let resolved = Self.resolvedCommand() else {
                showPlaceholder(
                    "Can't find \"\(programName)\".\n"
                        + "Install it, or point git_tool_command in ~/.config/attache.toml at it."
                )
                return
            }
            command = resolved
            workingDirectory = root
        }

        let base = TerminalConfiguration(startingFrom: .default) { builder in
            builder.withBackgroundOpacity(0)
            // A little air, unlike the tmux surface's 0: tmux fills its
            // rectangle to the cell, while lazygit draws borders that read as
            // clipped when they touch the rail's edge.
            builder.withCustom("window-padding-x", "4")
            builder.withCustom("window-padding-y", "2")
            // The same terminfo question the tmux surface asks, kept here for
            // a weaker reason and worth saying so: lazygit itself *survives*
            // an unresolvable terminal name — measured 2026-08-09, it drew its
            // whole interface with `TERM=xterm-ghostty` and `TERMINFO` pointed
            // at nothing, because tcell carries a table of its own rather than
            // reading terminfo the way tmux does. But `git_tool_command` is a
            // setting, and an ncurses program in that slot would exit with one
            // line. See `GhosttyTerminfo`.
            if let term = GhosttyTerminfo.termForSurface() {
                builder.withCustom("term", term)
            }
            builder.withCustom("command", command)
            // The path goes through ghostty's own config key rather than a
            // `cd` in the command line, so a root with a space or a quote in
            // it never meets a shell. Same category of choice as targeting
            // tmux by id. Absent for a remote root, which no local working
            // directory can name.
            if let workingDirectory {
                builder.withCustom("working-directory", workingDirectory)
            }
        }
        let controller = TerminalController(
            configSource: .generated(base.rendered),
            theme: AppSettings.terminalTheme(),
            terminalConfiguration: AppSettings.terminalConfiguration()
        )
        let view = TmuxTerminalView(frame: bounds)
        view.translatesAutoresizingMaskIntoConstraints = false
        let box = DelegateBox(owner: self)
        delegateBox = box
        view.delegate = box
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .exec)
        view.linkGesture = {
            AppSettings.linkClickEnabled ? AppSettings.linkModifier : nil
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(programName) in \(root)")

        // Bottom of the pile — see `build` for why the header must win.
        addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        terminalView = view
        terminalController = controller
        runningRoot = root
        runningHostID = hostEnv?.id
        placeholderLabel.isHidden = true
        reopenButton.isHidden = true
        TmuxLog.lifecycle("git tool started \(programName) in \(abbreviated(root))")
    }

    private func teardownChild() {
        guard let view = terminalView else { return }
        // Delegate first: libghostty holds it unowned-unsafe, and the surface
        // outlives this call by however long its teardown takes.
        view.delegate = nil
        view.setSurfaceVisible(false)
        view.removeFromSuperview()
        terminalView = nil
        terminalController = nil
        delegateBox = nil
        if let runningRoot {
            TmuxLog.lifecycle("git tool ended \(programName) in \(abbreviated(runningRoot))")
        }
        runningRoot = nil
        runningHostID = nil
    }

    private enum RemoteCommand {
        case command(String)
        case probing
        case missing
    }

    /// The remote command line, or the probe for it. `command -v` runs over
    /// the helper once per host per run; a configured command that names its
    /// own path is trusted as written, like the local walk.
    private func remoteCommand(env: HostEnv, root: String) -> RemoteCommand {
        let configured = configuredCommand
        let program = configured.split(separator: " ", maxSplits: 1).first.map(String.init)
        guard let program else { return .missing }

        var raw = configured
        if !program.contains("/") {
            switch remoteProgramByHost[env.id] {
            case .some(nil):
                return .missing
            case .some(let located?):
                let tail = configured.dropFirst(program.count)
                raw = TmuxTransport.shellQuote(located) + tail
            case nil:
                guard !remoteProbesInFlight.contains(env.id) else { return .probing }
                guard let helper = env.helper else { return .missing }
                remoteProbesInFlight.insert(env.id)
                helper.probe(program: program) { [weak self] outcome in
                    guard let self else { return }
                    self.remoteProbesInFlight.remove(env.id)
                    switch outcome {
                    case .answered(let path):
                        self.remoteProgramByHost[env.id] = .some(path)
                    case .absent:
                        self.remoteProgramByHost[env.id] = .some(nil)
                    case .unavailable:
                        // Not an answer — nothing cached, so the next reveal
                        // asks again once the channel is back.
                        break
                    }
                    self.reconcile()
                }
                return .probing
            }
        }
        guard let line = env.transport.remoteToolShellCommand(
            rawCommand: raw, quotedArguments: ["-p", root]
        ) else { return .missing }
        return .command(line)
    }

    private func showPlaceholder(_ text: String, reopen: Bool = false) {
        placeholderLabel.stringValue = text
        placeholderLabel.isHidden = false
        reopenButton.isHidden = !reopen
        terminalView?.isHidden = true
    }

    private func showChild() {
        placeholderLabel.isHidden = true
        reopenButton.isHidden = true
        terminalView?.isHidden = false
    }

    @objc private func reopenClicked() {
        exitedRoot = nil
        reconcile()
    }

    fileprivate func childDidClose() {
        exitedRoot = runningRoot
        teardownChild()
        showPlaceholder("\(programName) exited.", reopen: true)
    }

    fileprivate func openLink(_ raw: String) {
        // ⇧⌘ reaches libghostty's own link handling whatever the settings
        // say; `lastLinkPress` is what tells this app's configured gesture
        // from that back door. Same gate as the tmux surface's.
        guard AppSettings.linkClickEnabled, terminalView?.lastLinkPress != nil else { return }
        // No tmux to ask here: the child's directory is the root it was
        // started in, so a relative path resolves against that.
        let cwd = runningRoot

        if let env = hostEnv, !env.isLocal {
            guard let helper = env.helper else {
                onStatus?("Attaché: can't reach \(env.name) right now")
                return
            }
            RemoteLinkResolver.resolve(raw: raw, cwd: cwd, helper: helper) { [weak self] target in
                guard let self else { return }
                guard let target else {
                    self.onStatus?("Attaché: can't reach \(env.name) right now")
                    return
                }
                switch target {
                case let .url(url):
                    NSWorkspace.shared.open(url)
                case let .directory(path), let .file(path):
                    RemoteOpener.open(
                        path: path,
                        host: env.name,
                        destination: env.transport.ssh?.destination ?? env.name,
                        template: env.remoteOpenCommand,
                        status: { [weak self] message in self?.onStatus?(message) }
                    )
                case let .missing(path):
                    self.onStatus?("Attaché: no such path on \(env.name) — \(path)")
                case .unsupported:
                    self.onStatus?("Attaché: not a path this app can open — \(raw)")
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = TerminalLinkTarget.resolve(raw, cwd: cwd, existence: Self.existence)
            DispatchQueue.main.async { self?.perform(target, raw: raw) }
        }
    }

    private static func existence(_ path: String) -> TerminalLinkTarget.Existence {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        return isDirectory.boolValue ? .directory : .file
    }

    private func perform(_ target: TerminalLinkTarget, raw: String) {
        switch target {
        case let .url(url):
            NSWorkspace.shared.open(url)
        case let .directory(path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case let .file(path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case let .missing(path):
            onStatus?("Attaché: no such path — \(path)")
        case .unsupported:
            onStatus?("Attaché: not a path this app can open — \(raw)")
        }
    }

    /// The configured command, with a bare program name replaced by a full
    /// path. ghostty hands `command` to `/bin/sh -c`, and a GUI app's shell
    /// has no Homebrew on its PATH — so bare `lazygit` would quietly become
    /// "command not found" in a surface that closes before anyone reads it.
    /// A command that names its own path is trusted as written, flags and all.
    private static func resolvedCommand() -> String? {
        let configured = AppSettings.gitToolCommand
        let parts = configured.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let program = String(first)
        guard !program.contains("/") else { return configured }
        guard let located = locate(program) else { return nil }
        // Single-quoted for the same reason the tmux attach command is: the
        // one string interpolated into a shell line must not be able to end
        // its own quoting.
        let quoted = "'" + located.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return parts.count > 1 ? "\(quoted) \(parts[1])" : quoted
    }

    /// The same walk `TmuxControlClient.locateTmux` does, for the same reason.
    private static func locate(_ program: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(program)",
            "/usr/local/bin/\(program)",
            "/usr/bin/\(program)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = "'" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        which.arguments = ["-lc", "command -v \(quoted)"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// libghostty holds its delegate unowned-unsafe, so the conformance lives
    /// on an object this view owns — the same arrangement
    /// `EmbeddedSessionViewController` uses and for the same reason.
    private final class DelegateBox: NSObject, TerminalSurfaceCloseDelegate,
        TerminalSurfaceOpenURLDelegate
    {
        weak var owner: GitToolView?
        init(owner: GitToolView) { self.owner = owner }

        func terminalDidClose(processAlive _: Bool) {
            owner?.childDidClose()
        }

        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            owner?.openLink(url)
        }
    }
}
