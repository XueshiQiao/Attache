//
//  MarkdownTable.swift
//  Attache
//

import Cocoa

/// A reply's markdown, cut into the text `ConversationMarkdown` draws and
/// the tables it does not: drawn as text, a table came out as lines with
/// every cell cut short (screenshot, 2026-11-06).
enum MarkdownBlocks {
    enum Block {
        case text(String)
        case table(header: [String], rows: [[String]], align: [NSTextAlignment])
    }

    static func split(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [Block] = []
        var text: [String] = []
        var fenced = false
        var i = 0
        func flush() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            text = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            // GFM: the separator has exactly the header's columns, or the
            // two lines are not a table.
            if !fenced, i + 1 < lines.count, isRow(line), let align = separator(lines[i + 1]),
               align.count == cells(line).count {
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isRow(lines[i]) {
                    var row = cells(lines[i])
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    // More cells than the header (an unescaped `|` in a
                    // cell): kept, in the last column, rather than dropped.
                    if row.count > header.count {
                        let extra = row[(header.count - 1)...].joined(separator: " | ")
                        row = Array(row.prefix(header.count - 1)) + [extra]
                    }
                    rows.append(row)
                    i += 1
                }
                flush()
                let aligns = header.indices.map { $0 < align.count ? align[$0] : .left }
                blocks.append(.table(header: header, rows: rows, align: aligns))
                continue
            }
            text.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func isRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.count > 1
    }

    /// `|---|:---:|---:|`: the alignments, or nil when this is no separator.
    private static func separator(_ line: String) -> [NSTextAlignment]? {
        guard isRow(line) else { return nil }
        var out: [NSTextAlignment] = []
        for cell in cells(line) {
            let c = cell.trimmingCharacters(in: .whitespaces)
            let dashes = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .right : .left)
        }
        return out.isEmpty ? nil : out
    }

    /// A row's cells: split on `|`, not on `\|`, inline code spans, or
    /// `](<...>)` link destinations.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        // The closing border, unless the `|` is escaped: an odd run of
        // backslashes before it. `\\|` is an escaped backslash, then the border.
        if t.hasSuffix("|") {
            let slashes = t.dropLast().reversed().prefix { $0 == "\\" }.count
            if slashes % 2 == 0 { t.removeLast() }
        }
        var out: [String] = []
        var cur = ""
        var index = t.startIndex
        while index < t.endIndex {
            let ch = t[index]
            if ch == "\\" {
                let next = t.index(after: index)
                if next < t.endIndex, ConversationMarkdown.isASCIIPunctuation(t[next]) {
                    if t[next] == "|" {
                        cur.append("|")
                    } else {
                        cur.append("\\")
                        cur.append(t[next])
                    }
                    index = t.index(after: next)
                    continue
                }
            }
            let rest = t[index...]
            if ch == "`", let close = rest.dropFirst().firstIndex(of: "`") {
                cur += rest[rest.startIndex...close]
                index = rest.index(after: close)
                continue
            }
            if rest.hasPrefix("](<"),
               let closeAngle = ConversationMarkdown.findClosingAngleDestination(
                   in: t, from: t.index(index, offsetBy: 3)
               )
            {
                cur += t[index...closeAngle]
                index = t.index(after: closeAngle)
                continue
            }
            if ch == "|" {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
                index = t.index(after: index)
                continue
            }
            cur.append(ch)
            index = t.index(after: index)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}

/// A table as a grid, the phone's way (`ChatMarkdown.kt`): a semibold
/// header on a deeper fill, 1pt rules between cells, a rounded frame.
/// Columns take the width their longest cell wants; when that is wider than
/// the column of text, the wide columns give way and wrap, and once they are
/// down to `floor` the table scrolls sideways instead.
@MainActor
final class MarkdownTableView: NSView {
    private let header: [String]
    private let rows: [[String]]
    private let align: [NSTextAlignment]
    private let linkContext: ChatLinkContext
    private let scroll = TableScrollView()
    private let grid: TableGridView
    private var height: NSLayoutConstraint!
    private var laidOutFor: CGFloat = -1

    /// About ten Chinese characters a line; the phone's 160dp.
    private static let floor: CGFloat = 160
    private static let pad = NSSize(width: 10, height: 6)

    init(
        header: [String],
        rows: [[String]],
        align: [NSTextAlignment],
        linkContext: ChatLinkContext? = nil
    ) {
        let resolvedContext = linkContext ?? .localDefault
        self.header = header
        self.rows = rows
        self.align = align
        self.linkContext = resolvedContext
        self.grid = TableGridView(linkContext: resolvedContext)
        super.init(frame: .zero)
        grid.onIntrinsicHeightChange = { [weak self] in
            self?.relayoutForLoadedImage()
        }
        scroll.documentView = grid
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        height = heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        guard abs(bounds.width - laidOutFor) > 0.5, bounds.width > 0 else { return }
        laidOutFor = bounds.width
        let size = grid.lay(header: header, rows: rows, align: align, available: bounds.width,
                            floor: Self.floor, pad: Self.pad)
        grid.frame = NSRect(origin: .zero, size: size)
        if height.constant != size.height { height.constant = size.height }
    }

    private func relayoutForLoadedImage() {
        guard bounds.width > 0 else { return }
        laidOutFor = bounds.width
        let size = grid.remeasure(available: bounds.width, floor: Self.floor, pad: Self.pad)
        grid.frame = NSRect(origin: .zero, size: size)
        if height.constant != size.height {
            height.constant = size.height
            invalidateIntrinsicContentSize()
        }
        needsLayout = true
        linkContext.onLayoutInvalidated?()
    }
}

/// Scrolls sideways only; a vertical turn of the wheel goes on to the page.
private final class TableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // A table that fits has nothing to scroll sideways: every turn of
        // the wheel is the page's, or a diagonal swipe would stop the page.
        let fits = (documentView?.frame.width ?? 0) <= contentView.bounds.width + 1
        if fits || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The grid itself: measured once per width, drawn from those measures.
private final class TableGridView: NSView, NSTextViewDelegate {
    private final class CellEntry {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let view: NSTextView

        init(attributed: NSAttributedString, delegate: NSTextViewDelegate, accent: NSColor) {
            storage = NSTextStorage(attributedString: attributed)
            manager = NSLayoutManager()
            container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            view = NSTextView(frame: .zero, textContainer: container)
            view.delegate = delegate
            view.linkTextAttributes = [
                .foregroundColor: accent,
                .cursor: NSCursor.pointingHand,
            ]
            view.textContainerInset = .zero
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.isAutomaticLinkDetectionEnabled = false
            // Sized by the grid, which measured the cell; left resizable,
            // a cell that wrapped differently would grow into the next row.
            view.isVerticallyResizable = false
            view.isHorizontallyResizable = false
        }
    }

    var onIntrinsicHeightChange: (() -> Void)?
    private let linkContext: ChatLinkContext
    private var entries: [[CellEntry]] = []
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var pad = NSSize.zero
    private static let gap: CGFloat = 1

    init(linkContext: ChatLinkContext) {
        self.linkContext = linkContext
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    func lay(header: [String], rows: [[String]], align: [NSTextAlignment], available: CGFloat,
             floor: CGFloat, pad: NSSize) -> NSSize {
        self.pad = pad
        let allRows = [header] + rows
        if entries.count != allRows.count || entries.first?.count != header.count {
            subviews.forEach { $0.removeFromSuperview() }
            let theme = ChromeTheme.current
            let size = ChatRowViews.size - 0.5
            entries = allRows.enumerated().map { r, row in
                row.enumerated().map { c, text in
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = c < align.count ? align[c] : .left
                    paragraph.lineSpacing = 2
                    let font = r == 0 ? NSFont.systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
                    let rendered = Self.inline(text, font: font, theme: theme, paragraph: paragraph)
                    let entry = CellEntry(attributed: rendered, delegate: self, accent: theme.accent)
                    addSubview(entry.view)
                    MarkdownImageLoader.hydrate(
                        entry.storage,
                        context: linkContext,
                        maxSize: MarkdownImageAttachmentCell.tableMaxSize
                    ) { [weak self] in
                        self?.onIntrinsicHeightChange?()
                    }
                    return entry
                }
            }
        }
        return remeasure(available: available, floor: floor, pad: pad)
    }

    func remeasure(available: CGFloat, floor: CGFloat, pad: NSSize) -> NSSize {
        self.pad = pad
        guard let firstRow = entries.first, !firstRow.isEmpty else { return .zero }
        let columns = firstRow.count
        let gap = Self.gap
        let natural = (0..<columns).map { c in
            entries.map { ceil($0[c].storage.size().width) + 2 * pad.width }.max() ?? 0
        }
        widths = Self.fit(natural, available: available - gap * CGFloat(columns + 1), floor: floor)
        heights = entries.map { row in
            row.enumerated().map { c, entry in
                let innerWidth = max(1, widths[c] - 2 * pad.width)
                entry.container.size = NSSize(width: innerWidth, height: .greatestFiniteMagnitude)
                entry.manager.ensureLayout(for: entry.container)
                return ceil(entry.manager.usedRect(for: entry.container).height) + 2 * pad.height
            }.max() ?? 0
        }
        placeText()
        needsDisplay = true
        return NSSize(width: widths.reduce(0, +) + gap * CGFloat(columns + 1),
                      height: heights.reduce(0, +) + gap * CGFloat(heights.count + 1))
    }

    /// Each cell's text as a selectable TextKit 1 text view on its cell; the
    /// grid only paints the fills and rules.
    private func placeText() {
        var y = Self.gap
        for (r, row) in entries.enumerated() {
            var x = Self.gap
            for (c, entry) in row.enumerated() {
                let frame = NSRect(x: x, y: y, width: widths[c], height: heights[r]).insetBy(dx: pad.width, dy: pad.height)
                entry.view.frame = frame
                entry.container.size = NSSize(width: max(1, frame.width), height: .greatestFiniteMagnitude)
                entry.view.needsDisplay = true
                x += widths[c] + Self.gap
            }
            y += heights[r] + Self.gap
        }
    }

    /// The phone's `TableWidths.fit`: columns that want no more than an even
    /// share keep it, the rest split what is left, none below the floor.
    static func fit(_ natural: [CGFloat], available: CGFloat, floor: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available else { return natural }
        var open = Array(natural.indices)
        var left = available
        while !open.isEmpty {
            let share = left / CGFloat(open.count)
            let settled = open.filter { natural[$0] <= share }
            if settled.isEmpty { break }
            for c in settled { left -= natural[c] }
            open.removeAll { settled.contains($0) }
        }
        let share = open.isEmpty ? 0 : left / CGFloat(open.count)
        return natural.indices.map { open.contains($0) ? max(share, min(floor, natural[$0])) : natural[$0] }
    }

    /// Unified cell inline formatting via `ConversationMarkdown.inline`.
    private static func inline(
        _ text: String, font: NSFont, theme: ChromeTheme, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let cellStyle = ConversationMarkdown.Style(
            body: font,
            mono: .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
            bold: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
            text: theme.text,
            strong: theme.text,
            faint: theme.faintText,
            codeBackground: theme.hover,
            look: .plain,
            accent: theme.accent,
            codeText: theme.text,
            line: theme.separator
        )
        let out = NSMutableAttributedString(
            attributedString: ConversationMarkdown.inline(
                text, style: cellStyle, baseFont: font, defaultColour: theme.text
            )
        )
        out.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: out.length)
        )
        return out
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let target = ChatLinkContext.linkTargetString(from: link) {
            linkContext.open(target)
            return true
        }
        return MarkdownImageLoader.handleAttachmentClick(
            in: textView, at: charIndex, context: linkContext
        )
    }

    func textView(
        _ textView: NSTextView,
        clickedOn cell: any NSTextAttachmentCellProtocol,
        in cellFrame: NSRect,
        at charIndex: Int
    ) {
        _ = MarkdownImageLoader.handleAttachmentClick(
            in: textView, at: charIndex, context: linkContext
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !widths.isEmpty else { return }
        let theme = ChromeTheme.current
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        // The rules are the gaps: the whole grid in the rule colour first,
        // then every cell on top of it.
        theme.separator.setFill()
        bounds.fill()
        let headFill = theme.background.blended(withFraction: 0.07, of: theme.text) ?? theme.hover
        var y = Self.gap
        for (r, row) in entries.enumerated() {
            var x = Self.gap
            for c in row.indices {
                let cell = NSRect(x: x, y: y, width: widths[c], height: heights[r])
                (r == 0 ? headFill : theme.background.withAlphaComponent(1)).setFill()
                cell.fill()
                x += widths[c] + Self.gap
            }
            y += heights[r] + Self.gap
        }
        NSGraphicsContext.restoreGraphicsState()
        // Stroked on top as well: square cells reach past the 1pt gap at a
        // rounded corner, and the clip cut the frame away with them.
        theme.separator.setStroke()
        frame.lineWidth = 1
        frame.stroke()
    }
}
