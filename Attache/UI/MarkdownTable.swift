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
            if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))) }
            text = []
        }
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            if !fenced, i + 1 < lines.count, isRow(line), let align = separator(lines[i + 1]) {
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isRow(lines[i]) {
                    var row = cells(lines[i])
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(Array(row.prefix(header.count)))
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

    /// A row's cells: split on `|`, not on `\|`.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var escaped = false
        for ch in t {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
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
final class MarkdownTableView: NSView {
    private let header: [String]
    private let rows: [[String]]
    private let align: [NSTextAlignment]
    private let scroll = TableScrollView()
    private let grid = TableGridView()
    private var height: NSLayoutConstraint!
    private var laidOutFor: CGFloat = -1

    /// About ten Chinese characters a line; the phone's 160dp.
    private static let floor: CGFloat = 160
    private static let pad = NSSize(width: 10, height: 6)

    init(header: [String], rows: [[String]], align: [NSTextAlignment]) {
        self.header = header
        self.rows = rows
        self.align = align
        super.init(frame: .zero)
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
}

/// Scrolls sideways only; a vertical turn of the wheel goes on to the page.
private final class TableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The grid itself: measured once per width, drawn from those measures.
private final class TableGridView: NSView {
    private var cells: [[NSAttributedString]] = []
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var pad = NSSize.zero
    private static let gap: CGFloat = 1

    override var isFlipped: Bool { true }

    func lay(header: [String], rows: [[String]], align: [NSTextAlignment], available: CGFloat,
             floor: CGFloat, pad: NSSize) -> NSSize {
        self.pad = pad
        let theme = ChromeTheme.current
        let size = ChatRowViews.size - 0.5
        cells = ([header] + rows).enumerated().map { r, row in
            row.enumerated().map { c, text in
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = c < align.count ? align[c] : .left
                paragraph.lineSpacing = 2
                let font = r == 0 ? NSFont.systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
                return Self.inline(text, font: font, colour: theme.text, paragraph: paragraph)
            }
        }
        let columns = header.count
        let gap = Self.gap
        let natural = (0..<columns).map { c in
            cells.map { ceil($0[c].size().width) + 2 * pad.width }.max() ?? 0
        }
        widths = Self.fit(natural, available: available - gap * CGFloat(columns + 1), floor: floor)
        heights = cells.map { row in
            row.enumerated().map { c, text in
                ceil(text.boundingRect(with: NSSize(width: widths[c] - 2 * pad.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2 * pad.height
            }.max() ?? 0
        }
        needsDisplay = true
        return NSSize(width: widths.reduce(0, +) + gap * CGFloat(columns + 1),
                      height: heights.reduce(0, +) + gap * CGFloat(heights.count + 1))
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

    /// `**bold**` and `` `code` `` inside a cell.
    private static func inline(_ text: String, font: NSFont, colour: NSColor,
                               paragraph: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                var a = base
                a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                out.append(NSAttributedString(string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), attributes: a))
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                var a = base
                a[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                a[.backgroundColor] = ChromeTheme.current.hover
                out.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<end]), attributes: a))
                rest = rest[rest.index(after: end)...]
            } else {
                let next = rest.dropFirst().firstIndex { $0 == "*" || $0 == "`" } ?? rest.endIndex
                out.append(NSAttributedString(string: String(rest[rest.startIndex..<next]), attributes: base))
                rest = rest[next...]
            }
        }
        return out
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
        for (r, row) in cells.enumerated() {
            var x = Self.gap
            for (c, text) in row.enumerated() {
                let cell = NSRect(x: x, y: y, width: widths[c], height: heights[r])
                (r == 0 ? headFill : theme.background.withAlphaComponent(1)).setFill()
                cell.fill()
                text.draw(with: cell.insetBy(dx: pad.width, dy: pad.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
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
