//
//  ChatRowViews.swift
//  Attache
//

import Cocoa

/// The views `ChatPaneView` is built from. Each one draws what attache-cli
/// said and turns a click into a call on the page; none of them holds state
/// beyond whether a long row is open.
@MainActor
enum ChatRowViews {
    static var size: CGFloat { AppSettings.conversationFontSize + 1 }

    static func make(_ element: ChatElement, width: @escaping () -> CGFloat) -> NSView {
        switch element {
        case .row(.user(_, let text, let queued)):
            return UserBubble(text: text, caption: queued ? "Sent while it was working" : nil, faded: false)
        case .row(.agent(_, let text)):
            return AgentReply(markdown: text)
        case .row(.thinking(_, let text)):
            return ThinkingRow(text: text)
        case .row(.output(_, let text, let isError, _)):
            return OutputCard(text: text, isError: isError)
        case .row(.note(_, let text)), .note(_, let text):
            return Note(text: text)
        case .row(.tool):
            return ToolCard(steps: [element.rowValue].compactMap { $0 })
        case .pending(let message):
            return UserBubble(text: message.text,
                              caption: message.unconfirmed ? "Not confirmed yet — check the terminal" : "Sending…",
                              faded: true)
        }
    }

    static func label(_ text: String, font: NSFont, colour: NSColor, selectable: Bool = true) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = colour
        label.isSelectable = selectable
        label.translatesAutoresizingMaskIntoConstraints = false
        label.giveWayHorizontally()
        return label
    }

    static func pin(_ child: NSView, in parent: NSView, insets: NSEdgeInsets) {
        if let field = child as? NSTextField { field.giveWayHorizontally() }
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }

    static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }
}

extension NSTextField {
    /// Wraps instead of asking for the width of its longest line, and gives
    /// that width up before anything else does. A label that asked for it
    /// pushed the content half wider and squeezed the session rail to half
    /// its width (seen on screen, 2026-11-06).
    func giveWayHorizontally() {
        if lineBreakMode == .byClipping { lineBreakMode = .byWordWrapping }
        if maximumNumberOfLines != 1 {
            cell?.wraps = true
            cell?.isScrollable = false
        }
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
}

private extension ChatElement {
    var rowValue: ChatRow? {
        if case .row(let row) = self { return row }
        return nil
    }
}

private extension NSFont {
    var italic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}

/// An NSButton that calls a closure, so the docks need no target objects.
final class ClosureButton: NSButton {
    private var handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire() { handler() }
}

// MARK: - Rows

/// What the person said, on the right: a tint of the accent with ordinary
/// text, or the accent itself with white text, by `ChatStyle`.
private final class UserBubble: NSView {
    init(text: String, caption: String?, faded: Bool) {
        super.init(frame: .zero)
        let theme = ChromeTheme.current
        let solid = ChatStyle.current.userBubbleIsSolid
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.backgroundColor = (solid ? theme.accent.withAlphaComponent(faded ? 0.55 : 1)
            : theme.accent.withAlphaComponent(faded ? 0.08 : 0.15)).cgColor
        let body = ChatRowViews.label(text, font: .systemFont(ofSize: ChatRowViews.size),
                                      colour: solid ? theme.onAccent : theme.text)
        if faded, !solid { body.alphaValue = 0.7 }
        ChatRowViews.pin(body, in: bubble, insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12))
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        var constraints = [
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 90),
        ]
        if let caption {
            let small = ChatRowViews.label(caption, font: .systemFont(ofSize: 10.5), colour: theme.faintText,
                                           selectable: false)
            addSubview(small)
            constraints += [
                small.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 3),
                small.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
                small.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(bubble.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// What the agent said, as rendered markdown across the width.
private final class AgentReply: NSView {
    init(markdown: String, leading: CGFloat = 20) {
        super.init(frame: .zero)
        var style = ConversationMarkdown.Style.current
        style.body = .systemFont(ofSize: ChatRowViews.size)
        style.bold = .systemFont(ofSize: ChatRowViews.size, weight: .semibold)
        style.mono = .monospacedSystemFont(ofSize: ChatRowViews.size - 1.5, weight: .regular)
        let blocks = MarkdownBlocks.split(markdown)
        if blocks.contains(where: { if case .table = $0 { return true } else { return false } }) {
            // Tables drawn as grids between runs of text.
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 10
            for block in blocks {
                let view: NSView
                switch block {
                case .text(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    view = Self.textField(text, style: style)
                case .table(let header, let rows, let align):
                    view = MarkdownTableView(header: header, rows: rows, align: align)
                }
                column.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            if ChatStyle.current.repliesOnCards {
                let card = SolidCard()
                ChatRowViews.pin(column, in: card, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
                ChatRowViews.pin(card, in: self, insets: NSEdgeInsets(top: 0, left: leading, bottom: 0, right: 24))
            } else {
                ChatRowViews.pin(column, in: self, insets: NSEdgeInsets(top: 0, left: leading, bottom: 0, right: 24))
            }
            return
        }
        let body = Self.textField(markdown, style: style)
        guard ChatStyle.current.repliesOnCards else {
            ChatRowViews.pin(body, in: self, insets: NSEdgeInsets(top: 0, left: leading, bottom: 0, right: 24))
            return
        }
        // On glass a reply gets a solid card, so its text never sits on the
        // wallpaper.
        let card = SolidCard()
        ChatRowViews.pin(body, in: card, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        ChatRowViews.pin(card, in: self, insets: NSEdgeInsets(top: 0, left: leading, bottom: 0, right: 24))
    }

    private static func textField(_ markdown: String, style: ConversationMarkdown.Style) -> NSTextField {
        let body = NSTextField(labelWithAttributedString: ConversationMarkdown.rendered(markdown, style: style))
        body.maximumNumberOfLines = 0
        body.isSelectable = true
        // True, though nothing here is editable: a selectable field that may
        // not keep text attributes drops them the moment it is clicked, and
        // the whole reply redraws in the field's own smaller font (reported
        // 2026-11-06: "click a line and the text gets smaller").
        body.allowsEditingTextAttributes = true
        body.giveWayHorizontally()
        return body
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A row that shows its first lines until clicked: thinking, long output.
private final class Expandable: NSView {
    private let body: NSTextField
    private let lines: Int
    private var open = false

    init(text: String, font: NSFont, lines: Int, colour: NSColor, insets: NSEdgeInsets? = nil) {
        body = ChatRowViews.label(text, font: font, colour: colour, selectable: false)
        self.lines = lines
        super.init(frame: .zero)
        body.maximumNumberOfLines = lines
        body.lineBreakMode = .byTruncatingTail
        ChatRowViews.pin(body, in: self, insets: insets ?? NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 24))
        toolTip = "Click to show all of it"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var pressed = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    // Opened on mouse up, and only by a press that began here (CLAUDE.md:
    // track that a press started on the view).
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open.toggle()
        body.maximumNumberOfLines = open ? 0 : lines
        body.lineBreakMode = open ? .byWordWrapping : .byTruncatingTail
        body.isSelectable = open
        needsLayout = true
    }
}

/// A command's output: monospaced, in a card, thirty lines until clicked.
private final class OutputCard: NSView {
    init(text: String, isError: Bool) {
        super.init(frame: .zero)
        let theme = ChromeTheme.current
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = theme.hover.cgColor
        if isError { card.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor; card.layer?.borderWidth = 1 }
        let body = Expandable(text: text, font: .monospacedSystemFont(ofSize: ChatRowViews.size - 2, weight: .regular),
                              lines: 30, colour: theme.text, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        ChatRowViews.pin(body, in: card, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        ChatRowViews.pin(card, in: self, insets: NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A line of the page's own or the transcript's: an interruption, a `/clear`.
private final class Note: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = ChatRowViews.label(text, font: .systemFont(ofSize: 11), colour: ChromeTheme.current.faintText,
                                       selectable: false)
        label.alignment = .center
        ChatRowViews.pin(label, in: self, insets: NSEdgeInsets(top: 2, left: 40, bottom: 2, right: 40))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// Tool steps: a line each, opened by a click, as a timeline — a rule down
/// the left with a dot per step, consecutive steps joining up — or inside a
/// bordered card, by `ChatStyle`.
private final class ToolCard: NSView {
    init(steps: [ChatRow]) {
        super.init(frame: .zero)
        let theme = ChromeTheme.current
        let layout = ChatStyle.current.toolLayout
        let timeline = layout == .timeline
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        if layout == .card {
            card.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.borderWidth = 1
            card.layer?.borderColor = theme.separator.cgColor
        }
        for step in steps {
            guard case .tool(_, let name, let summary, let detail, let result, let isError, let diff) = step else { continue }
            let row = ToolStep(name: name, summary: summary, detail: detail, result: result,
                               isError: isError, diff: diff, mark: layout == .card, quiet: layout == .quiet)
            let shown: NSView = timeline ? TimelineRow(content: row, state: result == nil ? .running : isError ? .failed : .done) : row
            card.addArrangedSubview(shown)
            shown.widthAnchor.constraint(equalTo: card.widthAnchor, constant: layout == .card ? -20 : 0).isActive = true
        }
        ChatRowViews.pin(card, in: self, insets: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// One step on the timeline: the rule runs the full height, so steps drawn
/// with no gap between them read as one line.
private final class TimelineRow: NSView {
    enum State { case running, done, failed }
    private let state: State

    init(content: NSView, state: State) {
        self.state = state
        super.init(frame: .zero)
        ChatRowViews.pin(content, in: self, insets: NSEdgeInsets(top: 2, left: 20, bottom: 2, right: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ChromeTheme.current
        // The separator colour vanished on a dark scheme (screenshot,
        // 2026-11-06); the muted ink at a third reads on either.
        theme.mutedText.withAlphaComponent(0.35).setFill()
        NSRect(x: 5, y: 0, width: 1.5, height: bounds.height).fill()
        let dot = NSRect(x: 2.25, y: 8, width: 7, height: 7)
        let colour: NSColor = switch state {
        case .running: theme.accent
        case .done: .systemGreen
        case .failed: .systemRed
        }
        colour.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

private final class ToolStep: NSView {
    private let more = NSStackView()
    private let hasMore: Bool

    init(name: String, summary: String, detail: String, result: String?, isError: Bool,
         diff: [ChatRow.DiffLine], mark: Bool, quiet: Bool = false) {
        let theme = ChromeTheme.current
        // Mock-up A: 11.5 against the replies' 13.5.
        let size = ChatRowViews.size - (quiet ? 2.5 : 1)
        // … running, ✓ done, ✗ failed: a result lands on its call. On the
        // timeline the dot says it instead.
        let line = NSMutableAttributedString()
        if mark {
            let glyph = result == nil ? "…" : (isError ? "✗" : "✓")
            line.append(NSAttributedString(string: "\(glyph)  ", attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: isError ? NSColor.systemRed : theme.mutedText]))
        }
        line.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: theme.text]))
        if !summary.isEmpty {
            line.append(NSAttributedString(string: "  " + summary, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: theme.mutedText]))
        }
        let head: NSView
        if quiet {
            head = Self.quietHead(name: name, summary: summary, result: result, isError: isError, size: size)
        } else {
            let field = NSTextField(labelWithAttributedString: line)
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            head = field
        }
        head.translatesAutoresizingMaskIntoConstraints = false

        more.orientation = .vertical
        more.alignment = .leading
        more.spacing = 4
        more.isHidden = true
        more.translatesAutoresizingMaskIntoConstraints = false
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        if !detail.isEmpty, detail != summary {
            more.addArrangedSubview(ChatRowViews.label(detail, font: mono, colour: theme.mutedText))
        }
        if !diff.isEmpty { more.addArrangedSubview(DiffView(lines: diff, font: mono)) }
        if let result, !result.isEmpty {
            let shown = result.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n")
            more.addArrangedSubview(ChatRowViews.label(shown, font: mono, colour: isError ? .systemRed : theme.text))
        }
        hasMore = !more.arrangedSubviews.isEmpty
        super.init(frame: .zero)
        // A stack, not two pinned subviews: a hidden arranged view is taken
        // out of the layout, while a hidden plain subview keeps its height —
        // which drew every closed step as a tall empty box (seen on screen,
        // 2026-11-06).
        let column = NSStackView(views: [head, more])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        ChatRowViews.pin(column, in: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        // Indented by its own inset: the column already pins every view's
        // leading edge, and a second leading constraint would fight it.
        more.edgeInsets = NSEdgeInsets(top: 0, left: quiet ? 42 : 18, bottom: 0, right: 0)
        more.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        head.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor).isActive = true
        if hasMore { toolTip = "Click to show the details" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var pressed = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard hasMore, pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        more.isHidden.toggle()
    }

    /// A line that steps back from the replies: the tool's name as a small
    /// monospaced tag in a column of its own, what it did in grey, and its
    /// outcome last.
    private static func quietHead(name: String, summary: String, result: String?, isError: Bool,
                                  size: CGFloat) -> NSView {
        let theme = ChromeTheme.current
        // The numbers are mock-up A's (`docs/chat-hierarchy-designs.html`):
        // a 10.5 monospaced tag in the faint ink, 34pt wide; the summary in
        // the muted ink at 85%; the outcome faint. The first build used the
        // muted ink at full strength and a wider, larger tag, and the steps
        // read as loud as the replies (screenshots, 2026-11-06).
        let tag = NSTextField(labelWithString: name)
        tag.font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        tag.textColor = theme.faintText.withAlphaComponent(0.8)
        tag.lineBreakMode = .byTruncatingTail
        tag.translatesAutoresizingMaskIntoConstraints = false
        tag.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let what = NSTextField(labelWithString: summary)
        what.font = .systemFont(ofSize: size)
        what.textColor = theme.mutedText.withAlphaComponent(0.85)
        what.lineBreakMode = .byTruncatingTail
        what.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let outcome = NSTextField(labelWithString: result == nil ? "…" : (isError ? "✗" : "✓"))
        outcome.font = .systemFont(ofSize: size - 1.5)
        outcome.textColor = result == nil ? theme.faintText : (isError ? .systemRed : NSColor.systemGreen.withAlphaComponent(0.6))
        let row = NSStackView(views: [tag, what, outcome])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }
}

/// Thinking: set exactly as a reply is — the same size, colour and
/// markdown — with only a thin rule down the left to say what it is. Small
/// faint italics made it read as a footnote (the owner's call, 2026-11-06).
private final class ThinkingRow: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let reply = AgentReply(markdown: text, leading: 32)
        ChatRowViews.pin(reply, in: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ChromeTheme.current.separator.setFill()
        NSRect(x: 20, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// Removed lines on red, added on green, `…` for what was left out.
private final class DiffView: NSView {
    init(lines: [ChatRow.DiffLine], font: NSFont) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString()
        let theme = ChromeTheme.current
        for (i, line) in lines.enumerated() {
            let band: NSColor? = switch line.mark {
            case "-": NSColor.systemRed.withAlphaComponent(0.18)
            case "+": NSColor.systemGreen.withAlphaComponent(0.18)
            default: nil
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.text]
            if let band { attributes[.backgroundColor] = band }
            let shown = line.mark == "…" ? "…" : "\(line.mark) \(line.text)"
            text.append(NSAttributedString(string: shown + (i == lines.count - 1 ? "" : "\n"), attributes: attributes))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        // Keeps the bands and the mono font when clicked; see AgentReply.
        label.allowsEditingTextAttributes = true
        label.lineBreakMode = .byCharWrapping
        ChatRowViews.pin(label, in: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

// MARK: - Above and below the conversation

/// The agent's name, the way to its terminal, and what its status line says
/// as a row of chips under them.
final class ChatHeaderView: NSView {
    var onShowTerminal: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let chips = NSStackView()
    private let mode = NSSegmentedControl(labels: ["Chat", "Terminal"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    /// Where the conversation scrolls under: without it the top row reads as
    /// cut off by nothing.
    private let rule = NSBox()

    struct Chip {
        let text: String
        var dot: NSColor? = nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        rule.boxType = .separator
        chips.orientation = .horizontal
        chips.spacing = 6
        mode.selectedSegment = 0
        mode.controlSize = .small
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.toolTip = "Chat or terminal for this window (⇧⌘\\)"
        for v in [title, chips, mode, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        chips.setClippingResistancePriority(.init(1), for: .horizontal)
        applyChromeTheme()
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: mode.leadingAnchor, constant: -12),
            mode.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            mode.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chips.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            chips.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            chips.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// With pane cards on the title band has no height, and this is the top
    /// of the window: it has to drag it.
    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func modeChanged() {
        // The page only offers the way out; the half decides, and this page
        // is gone when it shows the terminal.
        mode.selectedSegment = 0
        onShowTerminal?()
    }

    func applyChromeTheme() {
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = ChromeTheme.current.text
    }

    func show(title: String, chips: [Chip]) {
        self.title.stringValue = title
        self.chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for chip in chips { self.chips.addArrangedSubview(ChipView(chip)) }
    }
}

extension ChatHeaderView {
    /// A tag as the header draws them; the current one in the accent.
    static func chip(_ text: String, current: Bool) -> NSView {
        let view = ChipView(Chip(text: text))
        if current {
            view.layer?.backgroundColor = ChromeTheme.current.accent.withAlphaComponent(0.25).cgColor
        }
        return view
    }
}

/// A rounded tag: a word or two, with a coloured dot when it is a state.
private final class ChipView: NSView {
    init(_ chip: ChatHeaderView.Chip) {
        super.init(frame: .zero)
        let theme = ChromeTheme.current
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = theme.hover.cgColor
        let label = NSTextField(labelWithString: chip.text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = theme.mutedText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var leading: CGFloat = 8
        if let colour = chip.dot {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = colour.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = 20
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A solid rounded card with a hairline, for whatever must not sit on glass.
final class SolidCard: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let theme = ChromeTheme.current
        layer?.cornerRadius = 12
        layer?.backgroundColor = theme.background.withAlphaComponent(1).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.separator.cgColor
    }
}

/// Claude's `✻ Verb… (13s · ↓ 649 tokens)`, and Stop.
final class ChatWorkingBar: NSView {
    var onStop: (() -> Void)?
    private let line = NSTextField(labelWithString: "")
    private lazy var stop = ChatRowViews.button("Stop") { [weak self] in self?.onStop?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stop.controlSize = .small
        addSubview(line)
        addSubview(stop)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -8),
            stop.trailingAnchor.constraint(equalTo: trailingAnchor),
            stop.topAnchor.constraint(equalTo: topAnchor),
            stop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var ticker: Timer?
    private var shown: (AgentActivity?, Int?) = (nil, nil)

    override var isHidden: Bool {
        didSet { if isHidden { ticker?.invalidate(); ticker = nil } else { tick() } }
    }

    /// The elapsed time counts on its own between screen updates.
    private func tick() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHidden else { return }
                self.draw(self.shown.0, since: self.shown.1)
            }
        }
    }

    func show(_ activity: AgentActivity?, since: Int?) {
        shown = (activity, since)
        draw(activity, since: since)
    }

    private func draw(_ activity: AgentActivity?, since: Int?) {
        let theme = ChromeTheme.current
        line.font = .systemFont(ofSize: 12)
        line.textColor = theme.mutedText
        let elapsed = since.map { "for \(Self.elapsed(Int(Date().timeIntervalSince1970) - $0))" }
        line.stringValue = "✻ " + [activity?.verb ?? "Working…", activity?.detail ?? elapsed]
            .compactMap { $0 }.joined(separator: "  ")
    }

    private static func elapsed(_ s: Int) -> String {
        s < 60 ? "\(max(0, s))s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s / 60 % 60)m"
    }
}

/// A permission menu: its question, its subject, and an answer a row, each
/// with its number and, when it needs a second click, why.
final class ChatApprovalDock: NSView {
    var onAnswer: ((ApprovalMenu.Option) -> Void)?
    private let stack = NSStackView()
    private var shown: ApprovalMenu?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        ChatRowViews.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ menu: ApprovalMenu?) {
        guard menu != shown else { return }
        shown = menu
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let menu else { return }
        let theme = ChromeTheme.current
        let question = ChatRowViews.label(menu.question, font: .systemFont(ofSize: 13, weight: .semibold),
                                          colour: theme.text)
        stack.addArrangedSubview(question)
        if !menu.subject.isEmpty {
            let subject = ChatRowViews.label(menu.subject.joined(separator: "\n"),
                                             font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                                             colour: theme.mutedText)
            let box = SolidCard()
            ChatRowViews.pin(subject, in: box, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for option in menu.options {
            let row = AnswerRow(option) { [weak self] in self?.onAnswer?(option) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// A question Claude asked: the tabs when there are several (ticked when
/// answered), the question, and an answer a row. A multiple choice ticks a
/// row per click and moves on with its own button; the last tab lists the
/// answers given, to submit or cancel. Answers that need typing point to
/// the terminal.
final class ChatQuestionDock: NSView {
    var onChoose: ((QuestionMenu.Option) -> Void)?
    var onSubmitChoices: (() -> Void)?
    var onShowTerminal: (() -> Void)?
    private let card = SolidCard()
    private let stack = NSStackView()
    private var shown: QuestionMenu?

    /// Wide enough for a sentence an answer; wider and the rows read as bars.
    static let maxWidth: CGFloat = 760

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        ChatRowViews.pin(stack, in: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            // Below the dock's own wish to fill the page (490): at the same
            // priority the layout gave that one up instead, and the whole
            // dock — the composer with it — shrank to the card's 760pt, even
            // with the card hidden (screenshot, 2026-11-06).
            card.widthAnchor.constraint(equalTo: widthAnchor).with(priority: .init(480)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ q: QuestionMenu?) {
        guard q != shown else { return }
        shown = q
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let q else { return }
        let theme = ChromeTheme.current
        let add = { (view: NSView, fill: Bool) in
            self.stack.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalTo: self.stack.widthAnchor).isActive = true }
        }

        // "Claude is asking", and where in the questions this is.
        let asking = ChatRowViews.label("● Claude is asking", font: .systemFont(ofSize: 11, weight: .semibold),
                                        colour: theme.accent, selectable: false)
        // Single words in a row: they keep their width, unlike paragraphs.
        asking.cell?.wraps = false
        asking.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var head: [NSView] = [asking]
        if !q.tabs.isEmpty {
            let current = q.review ? q.tabs.count : (q.tabs.firstIndex { !$0.answered } ?? q.tabs.count)
            for (k, tab) in q.tabs.enumerated() {
                head.append(Self.step("\(k + 1) \(tab.title)\(tab.answered ? " ✓" : "")", current: k == current, done: tab.answered))
            }
            head.append(Self.step("Review", current: q.review, done: false))
        } else if !q.header.isEmpty {
            head.append(Self.step(q.header, current: true, done: false))
        }
        let headRow = NSStackView(views: head)
        headRow.orientation = .horizontal
        headRow.spacing = 6
        headRow.setCustomSpacing(12, after: asking)
        add(headRow, false)

        add(ChatRowViews.label(q.question, font: .systemFont(ofSize: 14, weight: .semibold), colour: theme.text), true)
        if q.review {
            for (question, answer) in q.answers {
                let qa = NSMutableAttributedString(string: question + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.mutedText])
                qa.append(NSAttributedString(string: "→ " + answer, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: theme.text]))
                let line = NSTextField(labelWithAttributedString: qa)
                line.maximumNumberOfLines = 0
                line.giveWayHorizontally()
                add(line, true)
            }
        }
        // The answers this card can give, as rows; the typed ones as one
        // quiet line pointing to the terminal, not as answers that do
        // nothing here.
        for option in q.options where !option.typed {
            let row = AnswerRow(number: option.number, label: option.label,
                                detail: option.description.isEmpty ? nil : option.description,
                                note: nil, checkbox: q.multi ? option.checked : nil) { [weak self] in
                self?.onChoose?(option)
            }
            add(row, true)
        }
        let typed = q.options.filter(\.typed).map(\.label)
        var foot: [NSView] = []
        if !typed.isEmpty {
            let words = "Other answers: " + typed.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                .joined(separator: " · ") + " — in the terminal"
            let link = ClosureButton(title: words) { [weak self] in self?.onShowTerminal?() }
            link.isBordered = false
            link.attributedTitle = NSAttributedString(string: words, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.mutedText,
                .underlineStyle: NSUnderlineStyle.single.rawValue])
            foot.append(link)
        }
        if q.multi, q.submitRow {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            foot.append(spacer)
            let done = ChatRowViews.button(q.tabs.isEmpty ? "Done" : "Next question") { [weak self] in
                self?.onSubmitChoices?()
            }
            done.bezelColor = theme.accent
            foot.append(done)
        }
        if !foot.isEmpty {
            let row = NSStackView(views: foot)
            row.orientation = .horizontal
            row.spacing = 8
            add(row, true)
        }
    }

    /// A step: "1 Card position ✓", the current one in the accent.
    private static func step(_ text: String, current: Bool, done: Bool) -> NSView {
        let theme = ChromeTheme.current
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: current ? .semibold : .regular)
        label.textColor = current ? theme.text : (done ? theme.mutedText : theme.faintText)
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 9
        pill.layer?.backgroundColor = (current ? theme.accent.withAlphaComponent(0.25) : theme.hover).cgColor
        ChatRowViews.pin(label, in: pill, insets: NSEdgeInsets(top: 2, left: 9, bottom: 2, right: 9))
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return pill
    }
}

/// One answer: the whole row is the button.
private final class AnswerRow: NSView {
    private let action: () -> Void
    private var pressed = false

    convenience init(_ option: ApprovalMenu.Option, action: @escaping () -> Void) {
        self.init(number: option.number, label: option.label, detail: nil,
                  note: option.risk.map { "⚠︎ asks again: \($0)" }, action: action)
        toolTip = option.risk.map { "Asks first: this answer \($0)" }
    }

    init(number: Int, label: String, detail: String?, note: String?, enabled: Bool = true,
         checkbox: Bool? = nil, action: @escaping () -> Void) {
        self.action = enabled ? action : {}
        super.init(frame: .zero)
        let theme = ChromeTheme.current
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = theme.separator.cgColor
        layer?.backgroundColor = theme.hover.cgColor
        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = theme.mutedText
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.backgroundColor = theme.separator.cgColor
        let title = ChatRowViews.label(label, font: .systemFont(ofSize: 12.5, weight: detail == nil ? .regular : .medium),
                                       colour: theme.text, selectable: false)
        title.maximumNumberOfLines = 2
        let text: NSView
        if let detail, !detail.isEmpty {
            let small = ChatRowViews.label(detail, font: .systemFont(ofSize: 11.5), colour: theme.mutedText,
                                           selectable: false)
            small.maximumNumberOfLines = 3
            let column = NSStackView(views: [title, small])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            text = column
        } else {
            text = title
        }
        var views: [NSView] = [badge]
        if let checkbox { views.append(CheckBox(on: checkbox)) }
        views.append(text)
        if let note {
            let warn = NSTextField(labelWithString: note)
            warn.font = .systemFont(ofSize: 11)
            warn.textColor = .systemOrange
            warn.lineBreakMode = .byTruncatingTail
            warn.setContentCompressionResistancePriority(.init(2), for: .horizontal)
            views.append(warn)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        ChatRowViews.pin(row, in: self, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 12))
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 18).isActive = true
        if !enabled { alphaValue = 0.5 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // Lit under the pointer, so a row reads as a button before it is one.
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { paint() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func paint() {
        let theme = ChromeTheme.current
        layer?.borderColor = (hovered ? theme.accent : theme.separator).cgColor
        layer?.backgroundColor = (pressed ? theme.separator : hovered ? theme.accent.withAlphaComponent(0.1) : theme.hover).cgColor
    }

    // Pressed on mouse down, answered on mouse up inside: the CLAUDE.md
    // rule for anything a click commits.
    override func mouseDown(with event: NSEvent) {
        pressed = true
        paint()
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; paint() }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

/// A multiple choice's box: a rounded square, ticked in the accent.
private final class CheckBox: NSView {
    private let on: Bool

    init(on: Bool) {
        self.on = on
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 15), heightAnchor.constraint(equalToConstant: 15)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ChromeTheme.current
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
        if on {
            theme.accent.setFill()
            box.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 4, y: 7.5))
            tick.line(to: NSPoint(x: 6.5, y: 4.5))
            tick.line(to: NSPoint(x: 11, y: 10.5))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            theme.onAccent.setStroke()
            tick.stroke()
        } else {
            theme.mutedText.withAlphaComponent(0.7).setStroke()
            box.lineWidth = 1.2
            box.stroke()
        }
    }
}

/// Claude is asking something this page does not read: the terminal does.
final class ChatUnreadableDock: NSView {
    var onShowTerminal: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = ChatRowViews.label("Claude is asking something this page cannot answer yet.",
                                      font: .systemFont(ofSize: 12), colour: ChromeTheme.current.text,
                                      selectable: false)
        let open = ChatRowViews.button("Answer in the Terminal") { [weak self] in self?.onShowTerminal?() }
        addSubview(text)
        addSubview(open)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -8),
            open.trailingAnchor.constraint(equalTo: trailingAnchor),
            open.topAnchor.constraint(equalTo: topAnchor),
            open.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A panel Claude has open over its input box, as it looks on screen, with
/// the only keys such a panel is given: what a letter does depends on the
/// panel, so none is offered.
final class ChatPanelDock: NSView {
    var onKey: ((String) -> Void)?
    private let text = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.giveWayHorizontally()
        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.spacing = 6
        keys.translatesAutoresizingMaskIntoConstraints = false
        for (title, key) in [("↑", "Up"), ("↓", "Down"), ("Enter", "Enter"), ("Tab", "Tab"), ("Esc", "Escape")] {
            keys.addArrangedSubview(ChatRowViews.button(title) { [weak self] in self?.onKey?(key) })
        }
        addSubview(text)
        addSubview(keys)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            keys.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 6),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor),
            keys.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ rows: [String]?) {
        text.textColor = ChromeTheme.current.text
        text.stringValue = (rows ?? []).suffix(24).joined(separator: "\n")
    }
}

/// Where a message is typed. Return sends; ⇧Return is a new line (the
/// message still goes as one line, as on the phone: Claude's prompt would
/// take a newline as a send).
final class ChatComposer: NSView {
    var onSend: ((String) -> Bool)?
    var onPasteFiles: (([URL], @escaping (String) -> Void) -> Void)? {
        get { textView.onPasteFiles }
        set { textView.onPasteFiles = newValue }
    }
    var onPasteImage: ((Data, @escaping (String) -> Void) -> Void)? {
        get { textView.onPasteImage }
        set { textView.onPasteImage = newValue }
    }
    let textView = ComposerTextView()
    private let scroll = ComposerScrollView()
    /// The wheel, when the field has nothing of its own to scroll.
    var onWheel: ((NSEvent) -> Void)? {
        get { scroll.onWheel }
        set { scroll.onWheel = newValue }
    }
    /// The field's box. Its own view, drawing in `updateLayer`: colours set
    /// on the scroll view's layer were never drawn — the box could not be
    /// seen at all (screenshot, 2026-11-06).
    private let box = FieldBox()
    private let hint = NSTextField(labelWithString: "")
    private lazy var send = SendButton { [weak self] in self?.submit() }
    private var height: NSLayoutConstraint?

    var placeholder: String {
        get { hint.stringValue }
        set { hint.stringValue = newValue }
    }

    var isEnabled = true {
        didSet {
            textView.isEditable = isEnabled
            send.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.55
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Self.textInset, height: 8)
        // The system completion popup takes the Return that was meant to
        // send (CLAUDE.md, "Autocorrect eats Return in inline editors").
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onTextChange = { [weak self] in self?.textChanged() }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        hint.isEditable = false
        for v in [box, scroll, hint, send] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.minHeight)
        self.height = height
        // The send button sits inside the field, at its right end, level
        // with the last line.
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4),
            height,
            // Where the text view draws its first line: the field's inset,
            // the container inset and the line fragment padding.
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: Self.textInset + 5),
            hint.centerYAnchor.constraint(equalTo: scroll.topAnchor, constant: Self.minHeight / 2),
            send.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            send.centerYAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.minHeight / 2),
        ])
        applyChromeTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private static var minHeight: CGFloat { ceil(ChatRowViews.size * 1.25) + 18 }
    private static let textInset: CGFloat = 8

    func applyChromeTheme() {
        let theme = ChromeTheme.current
        // A step off the solid page it sits on.
        let field = theme.background.blended(withFraction: 0.06, of: theme.text) ?? theme.background
        box.fill = field
        box.border = theme.separator
        box.radius = ChatStyle.current.composerRadius(height: Self.minHeight)
        send.needsDisplay = true
        textView.font = .systemFont(ofSize: ChatRowViews.size)
        textView.textColor = theme.text
        textView.insertionPointColor = theme.text
        hint.font = .systemFont(ofSize: ChatRowViews.size)
        hint.textColor = theme.faintText
    }

    private func textChanged() {
        hint.isHidden = !textView.string.isEmpty
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + 16
        height?.constant = min(max(Self.minHeight, used), 160)
    }

    private func submit() {
        guard isEnabled else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, onSend?(text) == true else { return }
        textView.string = ""
        textChanged()
    }
}

/// The composer's scroller: it scrolls a long draft, and hands the wheel to
/// the conversation when the draft fits — otherwise a wheel turned over the
/// bottom of the page went nowhere.
final class ComposerScrollView: NSScrollView {
    var onWheel: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.height ?? 0) <= contentView.bounds.height + 1
        if fits, let onWheel { onWheel(event) } else { super.scrollWheel(with: event) }
    }
}

/// A rounded box that paints itself.
final class FieldBox: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var border: NSColor = .clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 10 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
    }
}

/// The round accent button with an arrow, inside the field.
final class SendButton: NSView {
    private let action: () -> Void
    private var pressed = false
    var isEnabled = true { didSet { needsDisplay = true } }

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        toolTip = "Send (Return)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Send")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ChromeTheme.current
        (isEnabled ? theme.accent : theme.separator).withAlphaComponent(pressed ? 0.7 : 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let arrow = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        arrow.move(to: NSPoint(x: c.x, y: c.y - 6))
        arrow.line(to: NSPoint(x: c.x, y: c.y + 6))
        arrow.move(to: NSPoint(x: c.x - 4.5, y: c.y + 1.5))
        arrow.line(to: NSPoint(x: c.x, y: c.y + 6))
        arrow.line(to: NSPoint(x: c.x + 4.5, y: c.y + 1.5))
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        theme.onAccent.setStroke()
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; needsDisplay = true }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

/// Return sends; ⇧Return and ⌥Return add a line.
final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onTextChange: (() -> Void)?
    /// Files or an image on the pasteboard: turned into text — paths on the
    /// agent's machine — by whoever knows which machine that is, and handed
    /// back to be inserted where the paste was.
    var onPasteFiles: (([URL], @escaping (String) -> Void) -> Void)?
    var onPasteImage: ((Data, @escaping (String) -> Void) -> Void)?

    /// Not NSTextView's own paste, which in a plain-text view takes a
    /// string or nothing: a screenshot or a file copied in Finder pasted
    /// nothing at all, with no sign why (reported 2026-11-06, "it pastes
    /// sometimes"). The terminal hands Claude a Ctrl-V to read the
    /// pasteboard itself; here the image becomes a file and its path is
    /// typed, the way the phone attaches images.
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        NSLog("%@", "chat paste: types \(pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none")")
        let at = selectedRange()
        let insert: (String) -> Void = { [weak self] text in
            guard let self else { return }
            let range = NSRange(location: min(at.location, (self.string as NSString).length), length: 0)
            self.insertText(text, replacementRange: range)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, let onPasteFiles {
            onPasteFiles(urls, insert)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            insertText(text, replacementRange: selectedRange())
            return
        }
        if let image = NSImage(pasteboard: pasteboard), let onPasteImage,
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onPasteImage(png, insert)
            return
        }
        NSLog("chat paste: nothing on the pasteboard this field can take")
        NSSound.beep()
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // A plain Return only: ⇧/⌥ add a line, ⌃/⌘ are someone else's
        // shortcut, and Return while an input method is composing commits
        // the composition (Chinese, Japanese) rather than the message.
        if isReturn, event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty,
           !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }
}
