//
//  MainViewController.swift
//  TmuxGUI
//

import Cocoa

/// The whole window: session rail on the left, the selected session's windows
/// and panes on the right.
///
/// The three levels the app exists to provide, top to bottom:
///
///     tmux session  →  a row in the left rail
///     tmux window   →  a tab in the top strip
///     tmux pane     →  a split in the content area
///
/// Session controllers are kept once created, so switching back to a session
/// shows content that stayed current while it was off screen — the connection
/// never detached.
@MainActor
final class MainViewController: NSViewController {
    let server: TmuxServer

    private let sidebar = SessionSidebarView(frame: .zero)
    private let container = NSView()
    private var controllers = [String: SessionViewController]()
    private var currentName: String?

    var onStatusChange: ((String) -> Void)?

    init(server: TmuxServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    var currentSession: SessionViewController? {
        guard let currentName else { return nil }
        return controllers[currentName]
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        container.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        // Content first, rail second. A sibling that draws gets a backing
        // layer taller than its own bounds on macOS 26 and will paint over
        // anything added before it — the window strip learned this the hard
        // way. Whatever must stay visible goes on top.
        view.addSubview(container)
        view.addSubview(sidebar)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SessionSidebarView.preferredWidth),

            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        sidebar.onSelect = { [weak self] name in self?.show(sessionNamed: name) }
        sidebar.onNew = { [weak self] in self?.server.newSession() }
        sidebar.onRename = { [weak self] old, new in
            self?.server.connection(for: old)?.renameSession(to: new)
        }

        server.onChange = { [weak self] in self?.refreshSidebar() }
        server.start()
    }

    // MARK: - Sessions

    private func refreshSidebar() {
        let entries = server.sessionNames.map { name -> SessionSidebarView.Entry in
            let connection = server.connection(for: name)
            return SessionSidebarView.Entry(
                name: name,
                windowCount: connection?.windows.count ?? 0,
                hasActivity: connection?.hasActivity ?? false
            )
        }

        // Whatever the app was showing may have been renamed or killed
        // elsewhere; fall back to the first session rather than a blank pane.
        if currentName == nil || !server.sessionNames.contains(currentName!) {
            if let first = server.sessionNames.first { show(sessionNamed: first) }
        }

        sidebar.update(entries: entries, selected: currentName)
    }

    func show(sessionNamed name: String) {
        guard currentName != name, let connection = server.connection(for: name) else { return }

        currentSession?.view.removeFromSuperview()
        currentSession?.removeFromParent()

        let controller: SessionViewController
        if let existing = controllers[name] {
            controller = existing
        } else {
            controller = SessionViewController(connection: connection)
            controller.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
            controllers[name] = controller
        }

        currentName = name
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        connection.announceStatus()
        refreshSidebar()
    }

    func showStatus(_ status: String, detail: String) {
        sidebar.showStatus(status, detail: detail)
    }

    /// ⌃⌘1-9 — the session-level counterpart of ⌘1-9 for windows.
    func selectSession(atSlot slot: Int) {
        guard slot >= 0, slot < server.sessionNames.count else { return }
        show(sessionNamed: server.sessionNames[slot])
    }

    func selectAdjacentSession(offset: Int) {
        let names = server.sessionNames
        guard !names.isEmpty, let current = currentName,
              let index = names.firstIndex(of: current) else { return }
        show(sessionNamed: names[(index + offset + names.count) % names.count])
    }

    func stop() {
        for controller in controllers.values { controller.stop() }
        server.stop()
    }
}
