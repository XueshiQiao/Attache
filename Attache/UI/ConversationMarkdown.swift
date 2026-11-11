//
//  ConversationMarkdown.swift
//  Attache
//

import AppKit

/// Something drawn beside or behind a run of rendered markdown that an
/// attributed string cannot say by itself: a heading's bar, a nested list's
/// guide line, a number's disc, a code block's box.
///
/// A class, and compared by identity on purpose: two list items side by side
/// carry equal-looking decorations, and value equality would merge their runs
/// into one, losing where the second item starts — which is where its tick
/// goes.
final class MarkdownDecoration: NSObject {
    enum Kind {
        /// A bar down the left of a heading.
        case headingBar
        /// A vertical line at `x` beside a nested list item, with a tick
        /// across to the item's first line.
        case guide(x: CGFloat)
        /// A disc behind the glyphs it is on: an ordered list's number.
        case disc(radius: CGFloat)
        /// A rounded box behind a whole code block, full width.
        case codeBox(padding: CGFloat, stroke: NSColor)
    }

    let kind: Kind
    let colour: NSColor

    init(_ kind: Kind, colour: NSColor) {
        self.kind = kind
        self.colour = colour
    }
}

/// Pure description of an inline `![alt](destination)` image emitted by
/// `ConversationMarkdown` without touching disk or network. Views that show
/// images (`MarkdownTextView`, `MarkdownTableView`) hydrate matching runs
/// asynchronously off the main thread.
struct MarkdownImageSpec: Hashable {
    let alt: String
    let destination: String
}

extension NSAttributedString.Key {
    static let markdownDecoration = NSAttributedString.Key("AttacheMarkdownDecoration")
    static let markdownImage = NSAttributedString.Key("AttacheMarkdownImage")
    static let markdownImageToken = NSAttributedString.Key("AttacheMarkdownImageToken")
    static let markdownImageLink = NSAttributedString.Key("AttacheMarkdownImageLink")
}

/// Renders the markdown an agent wrote into something readable in the rail or
/// on the chat page.
///
/// **Hand-written rather than `NSAttributedString(markdown:)`, and the reason
/// is tables.** Foundation's parser has no table support at all — a `| a | b |`
/// row comes through as literal pipes in the body font, where the columns do
/// not line up and the result is worse than the source. Agent replies in this
/// codebase are full of tables.
///
/// Scope covers what agents emit: inline bold, code, CommonMark links
/// (`[label](dest)`) and images (`![alt](dest)`), backslash escapes, ATX and
/// bold-line headings, bullet and numbered lists, tables, horizontal rules, and
/// fenced code.
enum ConversationMarkdown {

    struct Style {
        var body: NSFont
        var mono: NSFont
        var bold: NSFont
        var text: NSColor
        var strong: NSColor
        var faint: NSColor
        var codeBackground: NSColor
        /// How the blocks are set. `plain` is the conversation rail's;
        /// `guides` is the chat page's (`docs/chat-markdown-designs.html`,
        /// D with C's code blocks): room between blocks, inline code as
        /// coloured monospace with no box, and the `MarkdownDecoration`s
        /// that `MarkdownTextView` draws — so only it can show this look.
        var look: Look = .plain
        var accent: NSColor = .controlAccentColor
        /// Inline code's colour in the `guides` look.
        var codeText: NSColor = .systemOrange
        /// Guide lines and the code box's edge.
        var line: NSColor = .separatorColor
    }

    enum Look { case plain, guides }

    /// Rendered strings, keyed by the message and the look they were rendered
    /// for.
    ///
    /// **Rendering is pure and repeated, which is the whole case for a cache.**
    /// A rebuild re-renders every visible message, and the answer for a given
    /// message can only change when the font size or the theme does. Measured
    /// before this existed: 40ms to build nine turns, nearly all of it here.
    ///
    /// Bounded, because a long conversation would otherwise hold every message
    /// it has ever drawn: the rail shows one conversation at a time and only
    /// the open turns of it, so a few hundred entries covers every rebuild
    /// without the cache outliving what it is caching.
    @MainActor private static var cache = [Key: NSAttributedString]()
    @MainActor private static var cacheOrder = [Key]()
    private static let cacheLimit = 400

    private struct Key: Hashable {
        let text: String
        let size: CGFloat
        let colour: Int
        let look: Look
    }

    /// The same as `render`, memoised. Callers that draw the same message
    /// repeatedly — which is every caller — should use this.
    @MainActor
    static func rendered(_ markdown: String, style: Style) -> NSAttributedString {
        let key = Key(
            text: markdown, size: style.body.pointSize,
            colour: (style.text.hashValue &* 31 &+ style.strong.hashValue) &* 31 &+ style.accent.hashValue,
            look: style.look
        )
        if let hit = cache[key] { return hit }

        let value = render(markdown, style: style)
        cache[key] = value
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return value
    }

    /// Drop everything. Called when the theme changes, since the colours baked
    /// into the cached strings are then wrong.
    @MainActor
    static func flushCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    static func render(_ markdown: String, style: Style) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var afterList = false
        for block in parse(markdown) {
            output.append(draw(block, style: style, afterList: afterList))
            switch block {
            case .blank: break
            case .listItem: afterList = true
            default: afterList = false
            }
        }
        // Trailing blank lines are padding the layout already provides.
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        // TextKit gives the first paragraph no spacing before it, and a code
        // box draws its padding up into that spacing: first in a reply, its
        // top would be cut off. A hairline paragraph above makes it second.
        if style.look == .guides, output.length > 0, Guides.startsWithCode(output) {
            let hairline = NSMutableParagraphStyle()
            hairline.maximumLineHeight = 1
            output.insert(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: hairline,
            ]), at: 0)
        }
        return output
    }

    // MARK: - Splitting into blocks
    //
    // **Two passes rather than one, and tables are why.** Rendering line by
    // line cannot align a table: the column widths are not known until every
    // row has been seen. The first build did it in one pass and every table it
    // drew was ragged. Fenced code has the same shape of problem — a uniform
    // background needs a uniform width.

    fileprivate enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(bullet: String, text: String, depth: Int)
        case table(rows: [[String]], hasHeader: Bool)
        case code([String])
        case rule
        case blank
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks = [Block]()
        // Separate variables rather than one optional tuple: appending to a
        // tuple member rebuilt the whole row array each time, which is O(R²)
        // in the number of rows. Found by review 2026-08-02.
        var tableRows = [[String]]()
        var tableHasHeader = false
        var inTable = false
        var code: [String]?

        func closeTable() {
            if inTable, !tableRows.isEmpty {
                blocks.append(.table(rows: tableRows, hasHeader: tableHasHeader))
            }
            tableRows.removeAll()
            tableHasHeader = false
            inTable = false
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.hasPrefix("```") {
                if let body = code { blocks.append(.code(body)); code = nil }
                else { closeTable(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }

            if stripped.hasPrefix("|"), stripped.dropFirst().contains("|") {
                inTable = true
                let cells = splitRow(stripped)
                if cells.allSatisfy(isDashes) {
                    // The `|---|---|` line under a header. It carries one bit of
                    // information — that the row above is a header — and drawing
                    // it costs a line of a column that has few to spare.
                    tableHasHeader = true
                } else {
                    tableRows.append(cells)
                }
                continue
            }
            closeTable()

            if stripped.isEmpty { blocks.append(.blank); continue }
            if stripped.count >= 3, stripped.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                blocks.append(.rule)
                continue
            }
            if let heading = headingBlock(stripped) { blocks.append(heading); continue }
            if let marker = listMarker(stripped) {
                let bullet = marker.hasPrefix("-") || marker.hasPrefix("*") || marker.hasPrefix("+")
                    ? "•" : String(marker.dropLast())
                // Nesting is not supported, but the *indent* is kept so a
                // nested list at least reads as nested instead of collapsing
                // into one flat run of bullets.
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                blocks.append(.listItem(
                    bullet: bullet,
                    text: String(stripped.dropFirst(marker.count)),
                    depth: min(3, indent / 2)
                ))
                continue
            }
            blocks.append(.paragraph(stripped))
        }
        if let body = code { blocks.append(.code(body)) }
        closeTable()
        return blocks
    }

    private static func headingBlock(_ line: String) -> Block? {
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }
            guard hashes.count <= 4, line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
            return .heading(level: hashes.count, text: String(line.dropFirst(hashes.count + 1)))
        }
        // A whole line in bold is how replies in this codebase write a
        // sub-heading, and treating it as body text loses most of the structure
        // in a typical message.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4,
           !line.dropFirst(2).dropLast(2).contains("**") {
            return .heading(level: 4, text: String(line.dropFirst(2).dropLast(2)))
        }
        return nil
    }

    // MARK: - Drawing

    private static func draw(_ block: Block, style: Style, afterList: Bool) -> NSAttributedString {
        if style.look == .guides, let drawn = Guides.draw(block, style: style, afterList: afterList) {
            return drawn
        }
        switch block {
        case .blank:
            return NSAttributedString(string: "\n", attributes: [.font: style.body])
        case .rule:
            return drawRule(style: style)
        case let .heading(level, text):
            return drawHeading(level: level, text: text, style: style)
        case let .paragraph(text):
            return drawParagraph(text, style: style)
        case let .listItem(bullet, text, depth):
            return drawListItem(bullet: bullet, text: text, depth: depth, style: style)
        case let .table(rows, hasHeader):
            return drawTable(rows: rows, hasHeader: hasHeader, style: style)
        case let .code(body):
            return drawCode(body, style: style)
        }
    }

    /// Headings get real size steps.
    ///
    /// All four levels used to render at one weight and one size, so a reply
    /// with a title and three sub-headings arrived as four identical bold
    /// lines and read as no structure at all.
    private static func drawHeading(level: Int, text: String, style: Style) -> NSAttributedString {
        let base = style.body.pointSize
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: size = base + 3.5; weight = .bold
        case 2: size = base + 2; weight = .bold
        case 3: size = base + 0.5; weight = .semibold
        default: size = base; weight = .semibold
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = level <= 2 ? 8 : 5
        paragraph.paragraphSpacing = 2
        let result = NSMutableAttributedString(
            attributedString: inline(
                text, style: style, baseFont: .systemFont(ofSize: size, weight: weight),
                defaultColour: style.strong
            )
        )
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: style.strong]))
        result.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func drawParagraph(_ text: String, style: Style) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.5
        let result = NSMutableAttributedString(attributedString: inline(text, style: style))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(
            .paragraphStyle, value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// A hanging indent, so a wrapped item lines up under its own text rather
    /// than under the bullet.
    private static func drawListItem(
        bullet: String, text: String, depth: Int, style: Style
    ) -> NSAttributedString {
        let step = CGFloat(depth) * 14
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.5
        paragraphStyle.headIndent = 15 + step
        paragraphStyle.firstLineHeadIndent = 2 + step

        let result = NSMutableAttributedString(
            string: bullet + " ",
            attributes: [.font: style.body, .foregroundColor: style.faint]
        )
        result.append(inline(text, style: style))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(
            .paragraphStyle, value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// A real line, drawn with box-drawing characters in the monospaced face so
    /// the run joins up.
    ///
    /// It used to render as a blank line, which meant a reply saying "the rule
    /// above" pointed at nothing. The first attempt at drawing it used
    /// `faint` at half alpha and was still invisible on this app's translucent
    /// background — checked on screen, not reasoned about.
    private static func drawRule(style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 5
        paragraph.paragraphSpacing = 5
        return NSAttributedString(
            string: String(repeating: "\u{2500}", count: columnBudget(for: style)) + "\n",
            attributes: [
                .font: style.mono,
                .foregroundColor: style.faint,
                .paragraphStyle: paragraph,
            ]
        )
    }

    // MARK: - Tables and code, which need the whole block

    /// How many monospaced characters fit across the rail.
    ///
    /// **Measured from the font, not assumed.** This was a hard-coded 54,
    /// which is right only at the default size: the character advance is
    /// 6.80pt for the system monospaced face at 11pt (measured 2026-08-02, and
    /// 6.62pt for Menlo), so at the largest font size the setting allows, 54
    /// columns want 484pt in a rail that has 376. The table would then wrap,
    /// and a wrapped table has no alignment at all — the failure the whole
    /// two-pass renderer exists to prevent.
    ///
    /// Still pure: it asks the *font* for its advance, never a view for its
    /// width, so the result depends only on the style and stays cacheable.
    private static func columnBudget(for style: Style) -> Int {
        let available: CGFloat = 376   // 400pt rail less the 12pt margins each side
        let advance = ("W" as NSString).size(withAttributes: [.font: style.mono]).width
        return max(16, Int(available / max(1, advance)))
    }

    private static func drawTable(
        rows: [[String]], hasHeader: Bool, style: Style
    ) -> NSAttributedString {
        guard !rows.isEmpty else { return NSAttributedString() }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return NSAttributedString() }

        // Widen every column to its widest cell, then, if the row is wider than
        // the rail, take the surplus off the widest column first. Truncating
        // the widest keeps the narrow columns — usually the labels — intact.
        var widths = (0..<columns).map { index in
            rows.map { index < $0.count ? displayWidth(visibleText($0[index])) : 0 }.max() ?? 0
        }
        let gap = 2
        let budget = columnBudget(for: style)
        var total = widths.reduce(0, +) + gap * (columns - 1)
        while total > budget, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
              widths[widest] > 6
        {
            widths[widest] -= 1
            total -= 1
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 4
        paragraph.lineSpacing = 1
        // No wrapping: a wrapped cell destroys the alignment the whole exercise
        // is for. Cells are truncated to fit instead.
        paragraph.lineBreakMode = .byClipping

        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            let isHeader = hasHeader && rowIndex == 0
            for index in 0..<columns {
                if index > 0 {
                    result.append(NSAttributedString(
                        string: String(repeating: " ", count: gap),
                        attributes: [.font: style.mono]
                    ))
                }
                let raw = index < row.count ? row[index] : ""
                let cell = fit(raw, to: widths[index])
                let font = isHeader
                    ? NSFont.monospacedSystemFont(ofSize: style.mono.pointSize, weight: .bold)
                    : style.mono
                let piece = cell.isLiteral
                    ? NSMutableAttributedString(
                        string: cell.text,
                        attributes: [.font: font, .foregroundColor: isHeader ? style.strong : style.text]
                    )
                    : NSMutableAttributedString(
                        attributedString: inline(
                            cell.text, style: style, baseFont: font,
                            defaultColour: isHeader ? style.strong : nil
                        )
                    )
                // Padding outside the inline pass, so a cell's code background
                // stops at the text rather than running into the gap.
                if cell.padding > 0 {
                    piece.append(NSAttributedString(
                        string: String(repeating: " ", count: cell.padding),
                        attributes: [.font: font]
                    ))
                }
                result.append(piece)
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: style.mono]))
        }
        result.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// A fenced block, every line padded to the same width so the background
    /// is one rectangle instead of a ragged edge per line.
    private static func drawCode(_ body: [String], style: Style) -> NSAttributedString {
        let trimmed = body.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
        guard !trimmed.isEmpty else { return NSAttributedString() }

        let widest = min(columnBudget(for: style), trimmed.map { displayWidth($0) }.max() ?? 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 4
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 1

        let result = NSMutableAttributedString()
        for line in trimmed {
            let padding = max(0, widest - displayWidth(line))
            result.append(NSAttributedString(
                string: line + String(repeating: " ", count: padding) + "\n",
                attributes: [
                    .font: style.mono,
                    .foregroundColor: style.text,
                    .backgroundColor: style.codeBackground,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }

    // MARK: - Measuring text that is not all one width

    /// Columns a string occupies in a monospaced face.
    ///
    /// CJK characters are two cells wide and Latin ones are one, so counting
    /// `Character`s aligns nothing in a bilingual table — which is most tables
    /// this app draws.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isWide(scalar) ? 2 : 1)
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,      // kana, compatibility
             0x3400...0x4DBF,      // CJK extension A
             0x4E00...0x9FFF,      // CJK unified
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF:    // emoji
            return true
        default:
            return false
        }
    }

    /// What `inline` will actually put on screen, which is what a column has to
    /// be measured against.
    ///
    /// **Must consume markers exactly the way `inline` does.** Stripping every
    /// `**` and `` ` `` with a blind replace looks equivalent and is not: in
    /// `` `**text**` `` the asterisks are inside code and *do* reach the
    /// screen, so a blind strip measured that cell as four columns when it
    /// draws as eight, and the whole table shifted right from there. Caught by
    /// printing the rendered text with each line's width — the misalignment is
    /// four columns and invisible in a screenshot.
    static func visibleText(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    result.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            }
            let rest = text[index...]
            if ch == "`", let close = rest.dropFirst().firstIndex(of: "`") {
                result += rest[rest.index(after: rest.startIndex)..<close]
                index = rest.index(after: close)
                continue
            }
            if rest.hasPrefix("**"),
               let close = findClosingBold(in: text, from: text.index(index, offsetBy: 2)),
               close > text.index(index, offsetBy: 2)
            {
                let inner = String(text[text.index(index, offsetBy: 2)..<close])
                result += visibleText(inner)
                index = text.index(close, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("!["), let match = parseLinkOrImage(in: text, at: index, isImage: true) {
                let shownAlt = visibleText(match.label)
                result += "[" + (shownAlt.isEmpty ? "image" : shownAlt) + "]"
                index = match.afterIndex
                continue
            }
            if ch == "[", let match = parseLinkOrImage(in: text, at: index, isImage: false) {
                result += visibleText(match.label)
                index = match.afterIndex
                continue
            }
            result.append(ch)
            index = text.index(after: index)
        }
        return result
    }

    /// Truncate to a column budget and report how much padding is still owed.
    ///
    /// `isLiteral` says the text has already been reduced to what should appear
    /// and **must not be parsed again**. Feeding it back through `inline` is
    /// the defect this flag exists to prevent: a cell holding `` `**a**xyz` ``
    /// de-marks to `**a**xyz`, truncates to `**a**…`, and a second parse then
    /// eats `**a**` as bold and draws two columns where six were reserved —
    /// shifting every column after it. Found by review 2026-08-02.
    private static func fit(
        _ raw: String, to width: Int
    ) -> (text: String, padding: Int, isLiteral: Bool) {
        let visible = displayWidth(visibleText(raw))
        guard visible > width else { return (raw, width - visible, false) }

        // Truncation has to happen on the rendered text, not the source, or a
        // cut through `**` leaves a stray marker on screen.
        var kept = ""
        var used = 0
        for character in visibleText(raw) {
            let step = displayWidth(String(character))
            if used + step > width - 1 { break }
            kept.append(character)
            used += step
        }
        return (kept + "\u{2026}", max(0, width - used - 1), true)
    }

    /// Split a row on its separators — the ones that are actually separators.
    ///
    /// **A pipe inside inline code is content, not a column break.** Splitting
    /// on every `|` turns `` | `a|b` | c | `` into three cells, leaves the
    /// backticks unmatched so they render literally, and adds a phantom column
    /// to the whole table.
    ///
    /// **The rule for "inside code" is `inline`'s rule, character for
    /// character**, and that is the entire design of this function. A boolean
    /// that flips on every backtick is the obvious implementation and is
    /// subtly wrong: `inline` treats an *unmatched* backtick as a literal
    /// character, so a row like `` | a ` | b | c | `` has three real
    /// separators — while the toggle enters "code" at that backtick and eats
    /// both of them, collapsing three cells into one. Any divergence between
    /// the two shows up as a table whose columns were split somewhere its own
    /// renderer disagrees with. Found by review 2026-08-02.
    ///
    /// **One case is knowingly not CommonMark.** A triple-backtick span used
    /// inline — `` | ```a`|b``` | c | `` — splits into three cells here, where
    /// CommonMark's delimiter-run rule would give two. Matching that needs run
    /// counting in `inline` as well, and the two would have to be kept in step
    /// forever; a fenced-code marker inside a table cell that also contains a
    /// pipe is not worth that. What matters is that both functions agree, and
    /// they do: whatever this splits, `inline` renders the same way.
    static func splitRow(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }

        var cells = [String]()
        var current = ""
        var index = body.startIndex

        while index < body.endIndex {
            let ch = body[index]
            if ch == "\\" {
                let next = body.index(after: index)
                if next < body.endIndex, isASCIIPunctuation(body[next]) {
                    current.append(ch)
                    current.append(body[next])
                    index = body.index(after: next)
                    continue
                }
            }
            let rest = body[index...]
            // The same test `inline` makes: a backtick opens a code span only
            // when there is a closing one after it.
            if ch == "`", let close = rest.dropFirst().firstIndex(of: "`") {
                current += rest[rest.startIndex...close]
                index = rest.index(after: close)
                continue
            }
            // Pointy-bracket link destination `](<...>)` may contain `|`.
            if rest.hasPrefix("](<"),
               let closeAngle = findClosingAngleDestination(in: body, from: body.index(index, offsetBy: 3))
            {
                current += body[index...closeAngle]
                index = body.index(after: closeAngle)
                continue
            }
            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = body.index(after: index)
                continue
            }
            current.append(ch)
            index = body.index(after: index)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isDashes(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
    }

    // MARK: - Inline

    /// `**bold**`, `` `code` ``, `[label](dest)`, `![alt](dest)`, and CommonMark
    /// backslash escapes, in one pass.
    ///
    /// One pass because constructs can abut or nest (e.g. `` [`Sym`](url) `` or
    /// `[![alt](img)](href)`), and unmatched or malformed markers stay literal:
    /// an agent writing `[a] (b)` or `[a](b c)` sees exactly what it wrote.
    static func inline(
        _ text: String, style: Style, baseFont: NSFont? = nil, defaultColour: NSColor? = nil
    ) -> NSAttributedString {
        let font = baseFont ?? style.body
        let ink = defaultColour ?? style.text
        // **Bold and code have to stay in the caller's face.** Hard-coding
        // `style.bold` — a proportional font — inside a table cell measured in
        // monospaced columns is a silent misalignment: `**WW**` and `**ii**`
        // both count as two columns and draw at visibly different widths, so
        // the next column starts in a different place on each row. Derive both
        // from whatever font the caller asked for instead. Found by review
        // 2026-08-02.
        let boldFont = baseFont.map {
            NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask)
        } ?? style.bold
        let codeFont = (baseFont?.isFixedPitch == true) ? font : style.mono

        let result = NSMutableAttributedString()
        var plain = ""
        var index = text.startIndex

        func flush() {
            guard !plain.isEmpty else { return }
            result.append(NSAttributedString(
                string: plain, attributes: [.font: font, .foregroundColor: ink]
            ))
            plain = ""
        }

        while index < text.endIndex {
            let ch = text[index]
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    plain.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            }
            let rest = text[index...]
            if ch == "`", let close = rest.dropFirst().firstIndex(of: "`") {
                flush()
                var codeAttrs: [NSAttributedString.Key: Any] = [.font: codeFont]
                if style.look == .guides {
                    codeAttrs[.foregroundColor] = style.codeText
                } else {
                    codeAttrs[.foregroundColor] = ink
                    codeAttrs[.backgroundColor] = style.codeBackground
                }
                result.append(NSAttributedString(
                    string: String(rest[rest.index(after: rest.startIndex)..<close]),
                    attributes: codeAttrs
                ))
                index = rest.index(after: close)
                continue
            }
            if rest.hasPrefix("**"),
               let close = findClosingBold(in: text, from: text.index(index, offsetBy: 2)),
               close > text.index(index, offsetBy: 2)
            {
                flush()
                let inner = String(text[text.index(index, offsetBy: 2)..<close])
                result.append(inline(
                    inner, style: style, baseFont: boldFont, defaultColour: style.strong
                ))
                index = text.index(close, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("!["), let match = parseLinkOrImage(in: text, at: index, isImage: true) {
                flush()
                let shownAlt = visibleText(match.label)
                let placeholder = "[" + (shownAlt.isEmpty ? "image" : shownAlt) + "]"
                let spec = MarkdownImageSpec(alt: shownAlt, destination: match.destination)
                result.append(NSAttributedString(
                    string: placeholder,
                    attributes: [
                        .font: font,
                        .foregroundColor: style.accent,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: match.destination as NSString,
                        .markdownImage: spec,
                    ]
                ))
                index = match.afterIndex
                continue
            }
            if ch == "[", let match = parseLinkOrImage(in: text, at: index, isImage: false) {
                flush()
                let styled = NSMutableAttributedString(
                    attributedString: inline(
                        match.label, style: style, baseFont: font, defaultColour: style.accent
                    )
                )
                let whole = NSRange(location: 0, length: styled.length)
                if whole.length > 0 {
                    styled.addAttribute(.link, value: match.destination as NSString, range: whole)
                    styled.addAttribute(.foregroundColor, value: style.accent, range: whole)
                    styled.enumerateAttribute(.markdownImage, in: whole) { value, subrange, _ in
                        if value == nil {
                            styled.addAttribute(
                                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: subrange
                            )
                        }
                    }
                    result.append(styled)
                }
                index = match.afterIndex
                continue
            }
            plain.append(ch)
            index = text.index(after: index)
        }
        flush()
        return result
    }

    // MARK: - CommonMark inline link & image scanning

    struct InlineLinkMatch {
        let label: String
        let destination: String
        let afterIndex: String.Index
    }

    static func isASCIIPunctuation(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        switch ascii {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    static func findClosingAngleDestination<S: StringProtocol>(
        in text: S, from start: S.Index
    ) -> S.Index? {
        var cursor = start
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\n" || ch == "\r" || ch == "<" { return nil }
            if ch == "\\" {
                let next = text.index(after: cursor)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    cursor = text.index(after: next)
                    continue
                }
            }
            if ch == ">" { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func findClosingBold(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\\" {
                let next = text.index(after: cursor)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    cursor = text.index(after: next)
                    continue
                }
            }
            if ch == "`", let close = text[text.index(after: cursor)...].firstIndex(of: "`") {
                cursor = text.index(after: close)
                continue
            }
            if text[cursor...].hasPrefix("**") { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// Strict CommonMark inline `[label](destination "title")` and
    /// `![alt](destination "title")` parser.
    ///
    /// Rules enforced:
    /// - Zero characters allowed between `]` and `(`.
    /// - Balanced `[...]` inside the label, ignoring `\]` and backtick code spans.
    /// - Links (`isImage == false`) require a non-empty rendered label and may
    ///   not contain nested `[link](...)` links (CommonMark §6.3), though they
    ///   may wrap an image (`[![alt](img.png)](https://example.com)`).
    /// - Destinations inside `(...)` are either `<...>` (spaces allowed, no
    ///   newlines or unescaped `<`/`>`) or bare tokens with balanced `(...)`
    ///   and **no unescaped ASCII whitespace or control characters**.
    static func parseLinkOrImage(
        in text: String, at start: String.Index, isImage: Bool
    ) -> InlineLinkMatch? {
        let labelStart: String.Index
        if isImage {
            guard text[start...].hasPrefix("![") else { return nil }
            labelStart = text.index(start, offsetBy: 2)
        } else {
            guard text[start] == "[" else { return nil }
            labelStart = text.index(after: start)
        }

        // 1. Scan balanced `[...]` label.
        var depth = 1
        var cursor = labelStart
        var labelEnd: String.Index?
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\n" || ch == "\r" { return nil }
            if ch == "\\" {
                let next = text.index(after: cursor)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    cursor = text.index(after: next)
                    continue
                }
            }
            if ch == "`", let close = text[text.index(after: cursor)...].firstIndex(of: "`"),
               !text[text.index(after: cursor)..<close].contains(where: \.isNewline)
            {
                cursor = text.index(after: close)
                continue
            }
            if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    labelEnd = cursor
                    break
                }
            }
            cursor = text.index(after: cursor)
        }

        guard let labelEnd else { return nil }
        let label = String(text[labelStart..<labelEnd])

        // 2. `]` must be immediately followed by `(` — no whitespace in between.
        let openParen = text.index(after: labelEnd)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }

        // Links cannot contain nested links (CommonMark §6.3) and must produce
        // something clickable on screen; images may have an empty `alt`.
        if !isImage {
            if containsInlineLink(label) { return nil }
            if visibleText(label).isEmpty { return nil }
        }

        // 3. Scan destination and optional title up to matching `)`.
        var scan = skipHorizontalSpaces(in: text, from: text.index(after: openParen))
        guard scan < text.endIndex, text[scan] != ")" else { return nil }

        var destination = ""
        if text[scan] == "<" {
            var angle = text.index(after: scan)
            var closed = false
            while angle < text.endIndex {
                let ch = text[angle]
                if ch == "\n" || ch == "\r" || ch == "<" { return nil }
                if ch == "\\" {
                    let next = text.index(after: angle)
                    if next < text.endIndex, isASCIIPunctuation(text[next]) {
                        destination.append(text[next])
                        angle = text.index(after: next)
                        continue
                    }
                }
                if ch == ">" {
                    scan = text.index(after: angle)
                    closed = true
                    break
                }
                destination.append(ch)
                angle = text.index(after: angle)
            }
            guard closed, !destination.isEmpty else { return nil }
        } else {
            var parenDepth = 0
            while scan < text.endIndex {
                let ch = text[scan]
                if ch == ")" && parenDepth == 0 { break }
                if ch == " " || ch == "\t" { break }
                if ch.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                    return nil
                }
                if ch == "\\" {
                    let next = text.index(after: scan)
                    if next < text.endIndex, isASCIIPunctuation(text[next]) {
                        destination.append(text[next])
                        scan = text.index(after: next)
                        continue
                    }
                }
                if ch == "(" {
                    parenDepth += 1
                    destination.append(ch)
                } else if ch == ")" {
                    parenDepth -= 1
                    destination.append(ch)
                } else {
                    destination.append(ch)
                }
                scan = text.index(after: scan)
            }
            guard parenDepth == 0, !destination.isEmpty else { return nil }
        }

        // 4. Immediately `)`, or whitespace + optional quoted title + `)`.
        if scan < text.endIndex, text[scan] == ")" {
            return InlineLinkMatch(
                label: label, destination: destination, afterIndex: text.index(after: scan)
            )
        }
        guard scan < text.endIndex, text[scan] == " " || text[scan] == "\t" else { return nil }
        scan = skipHorizontalSpaces(in: text, from: scan)
        if scan < text.endIndex, text[scan] == ")" {
            return InlineLinkMatch(
                label: label, destination: destination, afterIndex: text.index(after: scan)
            )
        }
        // Optional CommonMark title in `"..."`, `'...'`, or `(...)`.
        guard scan < text.endIndex else { return nil }
        let opener = text[scan]
        let closer: Character
        switch opener {
        case "\"": closer = "\""
        case "'": closer = "'"
        case "(": closer = ")"
        default: return nil
        }
        scan = text.index(after: scan)
        var foundTitleClose = false
        while scan < text.endIndex {
            let ch = text[scan]
            if ch == "\n" || ch == "\r" { return nil }
            if opener == "(" && ch == "(" { return nil }
            if ch == "\\" {
                let next = text.index(after: scan)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    scan = text.index(after: next)
                    continue
                }
            }
            if ch == closer {
                scan = text.index(after: scan)
                foundTitleClose = true
                break
            }
            scan = text.index(after: scan)
        }
        guard foundTitleClose else { return nil }
        scan = skipHorizontalSpaces(in: text, from: scan)
        guard scan < text.endIndex, text[scan] == ")" else { return nil }
        return InlineLinkMatch(
            label: label, destination: destination, afterIndex: text.index(after: scan)
        )
    }

    private static func skipHorizontalSpaces(in text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func containsInlineLink(_ text: String) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, isASCIIPunctuation(text[next]) {
                    index = text.index(after: next)
                    continue
                }
            }
            if ch == "`", let close = text[text.index(after: index)...].firstIndex(of: "`") {
                index = text.index(after: close)
                continue
            }
            if text[index...].hasPrefix("![") {
                if let match = parseLinkOrImage(in: text, at: index, isImage: true) {
                    index = match.afterIndex
                    continue
                }
                index = text.index(index, offsetBy: 2)
                continue
            }
            if ch == "[", parseLinkOrImage(in: text, at: index, isImage: false) != nil {
                return true
            }
            index = text.index(after: index)
        }
        return false
    }

    // MARK: - Shapes

    private static func listMarker(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return marker
        }
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let digits = line[line.startIndex..<dot]
        guard digits.count <= 3, digits.allSatisfy(\.isNumber),
              line[dot...].dropFirst().hasPrefix(" ")
        else { return nil }
        return String(line[line.startIndex...dot]) + " "
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let cells = line.dropFirst().dropLast(line.hasSuffix("|") ? 1 : 0)
            .components(separatedBy: "|")
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// The first line of a message, for a collapsed progress row.
    ///
    /// Markers come off rather than being rendered: the row is one line of
    /// truncated text and a stray `**` in it reads as a typo.
    static func firstLine(of markdown: String) -> String {
        var line = String(markdown.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if let marker = listMarker(line) {
            line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return visibleText(line).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - The chat page's look

extension ConversationMarkdown {
    /// The `guides` look's blocks; nil hands a block back to the plain
    /// drawing (tables, rules).
    fileprivate enum Guides {
        static func startsWithCode(_ text: NSAttributedString) -> Bool {
            guard let d = text.attribute(.markdownDecoration, at: 0, effectiveRange: nil) as? MarkdownDecoration,
                  case .codeBox = d.kind else { return false }
            return true
        }

        /// `afterList`: the block follows a list, whose items sit close
        /// together, so a paragraph needs air of its own above it.
        static func draw(_ block: Block, style: Style, afterList: Bool) -> NSAttributedString? {
            switch block {
            case .blank:
                // Blocks carry their own spacing; a blank line on top of it
                // doubles every gap.
                return NSAttributedString()
            case let .heading(level, text):
                return heading(level: level, text: text, style: style)
            case let .paragraph(text):
                let p = paragraph(style, after: 8)
                if afterList { p.paragraphSpacingBefore = 6 }
                return finished(inline(text, style: style), p)
            case let .listItem(bullet, text, depth):
                return item(bullet: bullet, text: text, depth: depth, style: style)
            case let .code(body):
                return code(body, style: style)
            case .table, .rule:
                return nil
            }
        }

        /// Three steps, each about 8pt wider than the one inside it: lines
        /// (0.3 of the font), paragraphs (8 more), messages (`ChatPaneView`'s
        /// list spacing, 20). At 0.4 between lines and 9 after a paragraph a
        /// page read as one block — measured on a screenshot, two messages
        /// sat 4.5pt further apart than two lines.
        private static func paragraph(_ style: Style, after: CGFloat) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = (style.body.pointSize * 0.3).rounded()
            p.paragraphSpacing = after
            return p
        }

        private static func finished(_ text: NSAttributedString, _ paragraph: NSParagraphStyle,
                                     decoration: MarkdownDecoration? = nil) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            result.append(NSAttributedString(string: "\n", attributes: [.font: style(of: text)]))
            let whole = NSRange(location: 0, length: result.length)
            result.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if let decoration { result.addAttribute(.markdownDecoration, value: decoration, range: whole) }
            return result
        }

        private static func style(of text: NSAttributedString) -> NSFont {
            (text.length > 0 ? text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont : nil)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
        }

        /// A bar in the accent down its left, the text set in beside it.
        private static func heading(level: Int, text: String, style: Style) -> NSAttributedString {
            let base = style.body.pointSize
            let size = level <= 2 ? base + 2.5 : base + 1
            let p = paragraph(style, after: 7)
            p.paragraphSpacingBefore = level <= 2 ? 16 : 12
            p.firstLineHeadIndent = 13
            p.headIndent = 13
            let body = NSMutableAttributedString(attributedString: inline(
                text, style: style, baseFont: .systemFont(ofSize: size, weight: .bold),
                defaultColour: style.strong))
            return finished(body, p, decoration: MarkdownDecoration(.headingBar, colour: style.accent))
        }

        /// The first level a faint dot; deeper levels a guide line down the
        /// left with a tick to each item; a number sits on a disc.
        private static func item(bullet: String, text: String, depth: Int, style: Style) -> NSAttributedString {
            let p = paragraph(style, after: 4)
            let numbered = bullet != "•"
            // The disc is the number's mark; the parser hands over `1.`.
            let number = bullet.hasSuffix(".") ? String(bullet.dropLast()) : bullet
            // Where this level's text starts: 18 for the first level, and
            // each deeper level a guide (at +3) and its tick's width further.
            let guideX = 18 + CGFloat(max(0, depth - 1)) * 21 + 3
            let indent = depth == 0 ? (numbered ? 26 : 18) : guideX + 15
            p.headIndent = indent
            let result = NSMutableAttributedString()
            var decoration: MarkdownDecoration?
            if depth > 0 {
                decoration = MarkdownDecoration(.guide(x: guideX), colour: style.line)
                p.firstLineHeadIndent = indent
                if numbered {
                    result.append(NSAttributedString(string: number + ". ", attributes: [
                        .font: style.body, .foregroundColor: style.faint]))
                }
            } else if numbered {
                let font = NSFont.systemFont(ofSize: max(9, style.body.pointSize - 2.5), weight: .bold)
                let width = (number as NSString).size(withAttributes: [.font: font]).width
                let radius: CGFloat = 9
                p.firstLineHeadIndent = max(0, radius - width / 2)
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                result.append(NSAttributedString(string: number, attributes: [
                    .font: font, .foregroundColor: style.accent,
                    .baselineOffset: (style.body.pointSize - font.pointSize) / 3,
                    .markdownDecoration: MarkdownDecoration(
                        .disc(radius: radius), colour: style.accent.withAlphaComponent(0.16)),
                ]))
                result.append(NSAttributedString(string: "\t", attributes: [.font: style.body]))
            } else {
                p.firstLineHeadIndent = 4
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                result.append(NSAttributedString(string: "•\t", attributes: [
                    .font: style.body, .foregroundColor: style.faint]))
            }
            result.append(inline(text, style: style))
            let done = NSMutableAttributedString(attributedString: finished(result, p))
            if let decoration {
                done.addAttribute(.markdownDecoration, value: decoration,
                                  range: NSRange(location: 0, length: done.length))
            }
            return done
        }

        /// A rounded box with a faint fill and edge, full width, the code
        /// set in from its sides.
        private static func code(_ body: [String], style: Style) -> NSAttributedString {
            let trimmed = body.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
            guard !trimmed.isEmpty else { return NSAttributedString() }
            let padding: CGFloat = 10
            let box = MarkdownDecoration(.codeBox(padding: padding, stroke: style.line), colour: style.codeBackground)
            let result = NSMutableAttributedString()
            let lines = Array(trimmed)
            for (k, line) in lines.enumerated() {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 2
                p.firstLineHeadIndent = 13
                p.headIndent = 13
                p.tailIndent = -13
                if k == 0 { p.paragraphSpacingBefore = 6 + padding }
                if k == lines.count - 1 { p.paragraphSpacing = 9 + padding }
                result.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: style.mono, .foregroundColor: style.text, .paragraphStyle: p,
                    .markdownDecoration: box,
                ]))
            }
            return result
        }
    }
}

