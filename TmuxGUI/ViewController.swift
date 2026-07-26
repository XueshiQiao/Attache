import Cocoa
import GhosttyTerminal

private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// One window showing one tmux pane.
///
/// The only difference from libghostty's own AppKit sample is which backend
/// feeds the surface: the sample emulates a shell in-process so it can stay
/// inside the app sandbox, and this points the same `.inMemory` backend at a
/// real tmux server instead.
final class ViewController: NSViewController {
    private let tmuxPath: String
    private let sessionName: String

    private lazy var terminalView: TerminalView = .init(
        frame: NSRect(x: 0, y: 0, width: 900, height: 600)
    )

    private lazy var tmuxSession: TmuxPaneSession = .init(
        tmuxPath: tmuxPath,
        sessionName: sessionName
    )

    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
    }

    private var status = "启动中…"
    private var titleTimer: Timer?

    init(tmuxPath: String, sessionName: String) {
        self.tmuxPath = tmuxPath
        self.sessionName = sessionName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let container = AppearanceAwareView()
        container.onAppearanceChange = { [weak self] in
            self?.applyWindowBackgroundColor()
        }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureTerminalView()

        tmuxSession.onStatusChange = { [weak self] status in
            self?.status = status
            self?.refreshTitle()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
        tmuxSession.start()
        startTitleTimer()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Drives the surface's resize callback, which is what tells tmux our
        // size via `refresh-client -C`.
        terminalView.fitToSize()
    }

    /// Exposed so the menu can drive a measurement run against the live stream.
    var paneSession: TmuxPaneSession { tmuxSession }

    // MARK: - Setup

    private func configureView() {
        view.wantsLayer = true
        applyWindowBackgroundColor()
    }

    private func applyWindowBackgroundColor() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityIdentifier("terminal.surface")
        terminalView.setAccessibilityLabel("tmux pane")
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(tmuxSession.terminalSession)
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startTitleTimer() {
        titleTimer?.invalidate()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    private func refreshTitle() {
        let snapshot = tmuxSession.metrics.snapshot()
        view.window?.title = status
        view.window?.subtitle = snapshot.titleSummary
    }
}

// MARK: - Terminal Callbacks

extension ViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    // The pane's own title is deliberately dropped: the window title carries
    // tmux state and live throughput, which is what this spike is for.
    func terminalDidChangeTitle(_: String) {}

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        tmuxSession.stop()
        view.window?.close()
    }
}
