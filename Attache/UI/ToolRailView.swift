//
//  ToolRailView.swift
//  Attache
//

import AppKit

/// The right-hand rail as a whole: one tool showing, the others a click away.
///
/// The rail used to *be* the conversation; now the conversation is the first
/// of its tools and Git is the second. This container owns nothing but the
/// choice — which tool is up — and the pair of icons that make it. The tools
/// draw their own headers, so the icons sit *over* the header row, at its
/// right end, and each tool leaves that corner blank via
/// `reserveHeaderSpace`. Chosen over a tab strip of its own row in a mock-up
/// round on 2026-08-02: the rail is a reading column, and a second chrome row
/// would spend height on something two small glyphs can say.
///
/// Which tool is up is the fourth locally-authored fact in this app's UI,
/// beside the hidden window ids, `expandedSessions` and the open turns: it is
/// a fact about looking, and tmux has no opinion. It deliberately resets to
/// the conversation on relaunch — the conversation is why the rail exists;
/// Git is a tool you reach for.
final class ToolRailView: NSView {

    enum Tool {
        case conversation
        case git
    }

    private(set) var activeTool: Tool = .conversation
    /// Fired after the switch has been applied. `MainViewController` re-runs
    /// its refresh off this, because the visibility rule reads `activeTool`.
    var onActiveToolChanged: (() -> Void)?

    private let conversationView: ConversationSidebarView
    private let gitView: GitToolView
    private let conversationButton = RailButton()
    private let gitButton = RailButton()

    init(conversation: ConversationSidebarView, git: GitToolView) {
        conversationView = conversation
        gitView = git
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        for view in [conversationView, gitView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        for (button, symbol, tip, action) in [
            (conversationButton, "text.bubble",
             "Conversation", #selector(conversationClicked)),
            (gitButton, "arrow.triangle.branch",
             "Git (\(AppSettings.gitToolCommand))", #selector(gitClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imageScaling = .scaleProportionallyDown
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
        }

        let cluster = NSStackView(views: [conversationButton, gitButton])
        cluster.orientation = .horizontal
        cluster.spacing = 2
        cluster.translatesAutoresizingMaskIntoConstraints = false
        // Added after both tools, which is load-bearing twice over: hit
        // testing, and the macOS 26 sibling overdraw — the last sibling is the
        // one that survives the overlap (CLAUDE.md).
        addSubview(cluster)
        NSLayoutConstraint.activate([
            // 30pt down clears the title band; centred against the header's
            // two text lines (11pt + 3 + 10pt ≈ 27pt).
            cluster.centerYAnchor.constraint(equalTo: topAnchor, constant: 30 + 13),
            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])

        // 2 × 24pt of button, the 2pt between them, and air so a truncating
        // title does not touch the first glyph.
        conversationView.reserveHeaderSpace(58)
        gitView.reserveHeaderSpace(58)

        apply(tool: .conversation)
    }

    @objc private func conversationClicked() { select(.conversation) }
    @objc private func gitClicked() { select(.git) }

    func select(_ tool: Tool) {
        guard tool != activeTool else { return }
        apply(tool: tool)
        onActiveToolChanged?()
    }

    private func apply(tool: Tool) {
        activeTool = tool
        conversationView.isHidden = tool != .conversation
        gitView.isHidden = tool != .git
        gitView.isRevealed = tool == .git
        applyChromeTheme()
    }

    func applyChromeTheme() {
        let theme = ChromeTheme.current
        conversationView.applyChromeTheme()
        gitView.applyChromeTheme()
        for (button, tool) in [(conversationButton, Tool.conversation), (gitButton, .git)] {
            let active = tool == activeTool
            button.contentTintColor = active ? theme.text : theme.faintText
            button.layer?.backgroundColor = active ? theme.hover.cgColor : nil
        }
    }
}
