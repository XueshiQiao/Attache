//
//  ConversationMarkdown.swift
//  Attache
//

import AppKit

/// Renders the markdown an agent wrote into something readable in a 400pt
/// column.
///
/// **Hand-written rather than `NSAttributedString(markdown:)`, and the reason
/// is tables.** Foundation's parser has no table support at all — a `| a | b |`
/// row comes through as literal pipes in the body font, where the columns do
/// not line up and the result is worse than the source. Agent replies in this
/// codebase are full of tables. The rest of what Foundation would give is a few
/// lines here.
///
/// Scope is deliberately small: what agents actually emit into a terminal.
/// Inline bold and code, ATX and bold-line headings, bullet and numbered
/// lists, tables, horizontal rules, fenced code. No links, no images, no
/// blockquotes, no nesting — none of which appears often enough to earn the
/// ambiguity it would add.
enum ConversationMarkdown {

    struct Style {
        var body: NSFont
        var mono: NSFont
        var bold: NSFont
        var text: NSColor
        var strong: NSColor
        var faint: NSColor
        var codeBackground: NSColor
    }

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
    }

    /// The same as `render`, memoised. Callers that draw the same message
    /// repeatedly — which is every caller — should use this.
    @MainActor
    static func rendered(_ markdown: String, style: Style) -> NSAttributedString {
        let key = Key(
            text: markdown, size: style.body.pointSize,
            colour: style.text.hashValue &* 31 &+ style.strong.hashValue
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
        for block in parse(markdown) {
            output.append(draw(block, style: style))
        }
        // Trailing blank lines are padding the layout already provides.
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
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

    private enum Block {
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

    private static func draw(_ block: Block, style: Style) -> NSAttributedString {
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
                text, style: style, baseFont: .systemFont(ofSize: size, weight: weight)
            )
        )
        result.append(NSAttributedString(string: "\n"))
        result.addAttributes(
            [.foregroundColor: style.strong, .paragraphStyle: paragraph],
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
                        attributes: [.font: font, .foregroundColor: style.text]
                    )
                    : NSMutableAttributedString(
                        attributedString: inline(cell.text, style: style, baseFont: font)
                    )
                // Padding outside the inline pass, so a cell's code background
                // stops at the text rather than running into the gap.
                if cell.padding > 0 {
                    piece.append(NSAttributedString(
                        string: String(repeating: " ", count: cell.padding),
                        attributes: [.font: font]
                    ))
                }
                if isHeader {
                    piece.addAttribute(
                        .foregroundColor, value: style.strong,
                        range: NSRange(location: 0, length: piece.length)
                    )
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
            let rest = text[index...]
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                result += rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
                index = close.upperBound
                continue
            }
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                result += rest[rest.index(after: rest.startIndex)..<close]
                index = rest.index(after: close)
                continue
            }
            result.append(text[index])
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
            let rest = body[index...]
            // The same test `inline` makes: a backtick opens a code span only
            // when there is a closing one after it.
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                current += rest[rest.startIndex...close]
                index = rest.index(after: close)
                continue
            }
            if body[index] == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = body.index(after: index)
                continue
            }
            current.append(body[index])
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

    /// `**bold**` and `` `code` ``, in one pass.
    ///
    /// One pass because the two can abut and a second pass over an attributed
    /// string would have to re-find ranges it had already styled. Unmatched
    /// markers are left as literal text: an agent writing about `**` should see
    /// what it wrote.
    static func inline(
        _ text: String, style: Style, baseFont: NSFont? = nil
    ) -> NSAttributedString {
        let font = baseFont ?? style.body
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
                string: plain, attributes: [.font: font, .foregroundColor: style.text]
            ))
            plain = ""
        }

        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                flush()
                result.append(NSAttributedString(
                    string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]),
                    attributes: [.font: boldFont, .foregroundColor: style.strong]
                ))
                index = close.upperBound
                continue
            }
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                flush()
                result.append(NSAttributedString(
                    string: String(rest[rest.index(after: rest.startIndex)..<close]),
                    attributes: [
                        .font: codeFont,
                        .foregroundColor: style.text,
                        .backgroundColor: style.codeBackground,
                    ]
                ))
                index = rest.index(after: close)
                continue
            }
            plain.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return result
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
        let line = markdown.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
        return line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
