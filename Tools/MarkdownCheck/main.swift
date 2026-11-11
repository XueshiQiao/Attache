//
//  main.swift
//  MarkdownCheck
//
//  Cross-check for `ConversationMarkdown`.
//
//      swiftc -O -o /tmp/mdcheck \
//          Attache/UI/ConversationMarkdown.swift Tools/MarkdownCheck/main.swift
//      /tmp/mdcheck
//
//  **The defects this catches are invisible in a screenshot.** A table column
//  four cells too wide, a code block whose last line is short of the others —
//  both look plausible on screen and both are obvious the moment the rendered
//  text is printed with each line's width beside it. That is the whole method
//  here: render, then measure, then assert the columns line up.
//
//  Alignment is asserted on *display width*, not character count, because a
//  CJK character occupies two cells in a monospaced face and most tables this
//  app draws are bilingual.
//

import AppKit

let style = ConversationMarkdown.Style(
    body: .systemFont(ofSize: 12.5),
    mono: .monospacedSystemFont(ofSize: 11, weight: .regular),
    bold: .systemFont(ofSize: 12.5, weight: .semibold),
    text: .white, strong: .white, faint: .gray, codeBackground: .darkGray
)

var failures = 0

func fail(_ what: String, _ detail: String = "") {
    failures += 1
    print("FAIL  \(what)")
    if !detail.isEmpty { print("      \(detail)") }
}

func lines(of markdown: String) -> [String] {
    ConversationMarkdown.render(markdown, style: style).string
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

func widths(of rendered: [String]) -> [Int] {
    rendered.map { ConversationMarkdown.displayWidth($0) }
}

// MARK: - visibleText: what actually reaches the screen
//
// Everything about alignment rests on this being exactly what `inline`
// produces. A blind strip of every `**` and backtick is the natural way to
// write it and is wrong — inside code the asterisks survive.

for (source, expected, note) in [
    ("**bold**", "bold", "bold markers are consumed"),
    ("`code`", "code", "backticks are consumed"),
    ("`**text**`", "**text**", "REGRESSION asterisks inside code reach the screen"),
    ("a **b** c `d` e", "a b c d e", "mixed"),
    ("**unclosed", "**unclosed", "an unclosed marker is literal"),
    ("plain 中文", "plain 中文", "untouched"),
    ("[F01-A](file:///tmp/a.png)", "F01-A", "link shows its label"),
    ("![F01-A](file:///tmp/a.png)", "[F01-A]", "image shows bracketed alt before hydration"),
    ("![](file:///tmp/a.png)", "[image]", "empty image alt uses fallback word"),
    ("[`Sym`](file:///a.swift#L10)", "Sym", "code inside link label"),
    ("**[F01-A](file:///a.png)**", "F01-A", "link inside bold"),
    (#"\[F01-A](file:///a.png)"#, "[F01-A](file:///a.png)", "escaped bracket stays literal"),
    ("[a] (https://example.com)", "[a] (https://example.com)", "space between ] and ( stays literal"),
    ("[a](https://example.com/x y)", "[a](https://example.com/x y)", "raw space in bare destination stays literal"),
] {
    let actual = ConversationMarkdown.visibleText(source)
    if actual != expected {
        fail("visibleText — \(note)", "\(source.debugDescription) → \(actual.debugDescription), 期望 \(expected.debugDescription)")
    }
}

// MARK: - displayWidth: CJK is two cells

for (text, expected) in [("abc", 3), ("中文", 4), ("a中b", 4), ("", 0), ("（）", 4)] {
    let actual = ConversationMarkdown.displayWidth(text)
    if actual != expected {
        fail("displayWidth(\(text.debugDescription))", "得到 \(actual)，期望 \(expected)")
    }
}

// MARK: - Tables line up

func checkTable(_ name: String, _ markdown: String) {
    let rendered = lines(of: markdown).filter { !$0.isEmpty }
    guard rendered.count >= 2 else { return fail(name, "渲染出的行数不足: \(rendered.count)") }
    let measured = widths(of: rendered)
    if Set(measured).count != 1 {
        fail(name, "各行宽度不一致: \(measured)\n      " + rendered.joined(separator: "\n      "))
    }
}

checkTable("三列表格，含代码单元格", """
| 元素 | 是否渲染 | 备注 |
|---|---|---|
| 加粗 | 是 | `**text**` |
| 行内代码 | 是 | 带底色 |
| 表格 | 是 | 就是这个 |
""")

checkTable("两列中英混排", """
| Setting | 说明 |
|---|---|
| `conversation_width` | 侧边栏宽度，默认 400pt |
| `conversation_font_size` | 正文字号，默认 12.5 |
""")

checkTable("单元格带粗体", """
| A | B |
|---|---|
| **粗** | 普通 |
| 普通 | **bold** |
""")

checkTable("有空单元格", """
| A | B | C |
|---|---|---|
| x |  | z |
""")

// A table wider than the rail must still line up — it is truncated, not
// wrapped, because a wrapped cell destroys the alignment entirely.
checkTable("超宽表格被截断而不是换行", """
| 名字 | 描述 |
|---|---|
| 短 | 这一段描述非常非常长，长到超过侧边栏一行放得下的宽度，必须被截断掉才能保持对齐 |
| 也短 | 短描述 |
""")

// MARK: - The four defects review found on 2026-08-02
//
// Every one of them shifts a table sideways without looking broken.

// A truncated cell must not be re-parsed. `**a**xyz` cut to `**a**…` and
// handed back to the inline parser draws as `a…` — two columns where six were
// reserved.
checkTable("REGRESSION 截断后的内容不会被当成 markdown 二次解析", """
| A | B | C | D | E | F | G | H |
|---|---|---|---|---|---|---|---|
| `**a**xyz` | abcdefgh | abcdefgh | abcdefgh | abcdefgh | abcdefgh | abcdefgh | abcdefgh |
""")

// A pipe inside inline code is content. Splitting on it adds a phantom column.
do {
    let markdown = "| A | B |\n|---|---|\n| `a|b` | c |"
    let rendered = lines(of: markdown).filter { !$0.isEmpty }
    let measured = widths(of: rendered)
    if Set(measured).count != 1 {
        fail("REGRESSION 代码里的竖线不是列分隔符", "各行宽度 \(measured): \(rendered)")
    }
    if !rendered.contains(where: { $0.contains("a|b") }) {
        fail("REGRESSION 代码里的竖线应保留在同一格", rendered.joined(separator: " / "))
    }
}

// Bold inside a table must stay monospaced, or two cells of equal column count
// draw at different widths.
do {
    let rendered = ConversationMarkdown.render(
        "| A | B |\n|---|---|\n| **WW** | x |\n| **ii** | y |", style: style
    )
    var proportional = false
    rendered.enumerateAttribute(
        .font, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
        if let font = value as? NSFont, !font.isFixedPitch { proportional = true }
    }
    if proportional {
        fail("REGRESSION 表格里的粗体必须仍是等宽字体", "出现了比例字体，列宽会对不上")
    }
}

// Parsing must not be quadratic in row count.
do {
    var big = "| a | b |\n|---|---|\n"
    for index in 0..<4000 { big += "| row\(index) | value\(index) |\n" }
    let started = Date()
    _ = ConversationMarkdown.render(big, style: style)
    let seconds = Date().timeIntervalSince(started)
    if seconds > 2 {
        fail("REGRESSION 4000 行表格解析过慢", String(format: "耗时 %.1f 秒，疑似 O(R²)", seconds))
    }
}

// The rail is a fixed 400pt but the font size is a setting. A table has to
// stay inside the rail at every size it allows, or it wraps — and a wrapped
// table has no alignment at all. Measured 2026-08-02: the system monospaced
// advance is 6.80pt at 11pt, so a budget fixed at the default size overflows
// by more than 100pt at the largest.
for bodySize in [CGFloat(10), 12.5, 14, 16] {
    let sized = ConversationMarkdown.Style(
        body: .systemFont(ofSize: bodySize),
        mono: .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular),
        bold: .systemFont(ofSize: bodySize, weight: .semibold),
        text: .white, strong: .white, faint: .gray, codeBackground: .darkGray
    )
    let rendered = ConversationMarkdown.render("""
    | 名字 | 描述 |
    |---|---|
    | 短 | 这一段描述非常非常长，长到超过侧边栏一行放得下的宽度，必须被截断才能保持对齐 |
    """, style: sized)
    let advance = ("W" as NSString).size(withAttributes: [.font: sized.mono]).width
    for line in rendered.string.split(separator: "\n") where !line.isEmpty {
        let points = CGFloat(ConversationMarkdown.displayWidth(String(line))) * advance
        if points > 376 {
            fail(
                "REGRESSION 字号 \(bodySize) 时表格超出侧边栏",
                String(format: "该行需要 %.0fpt，可用 376pt", points)
            )
            break
        }
    }
}

// MARK: - Code blocks are one rectangle

do {
    let rendered = lines(of: """
    ```
    swiftc -O -o /tmp/x
        a.swift
    b
    ```
    """).filter { !$0.isEmpty }
    let measured = widths(of: rendered)
    if Set(measured).count != 1 {
        fail("代码块每行应补齐到同宽", "得到 \(measured)")
    }
}

// MARK: - The rule is a line, not a blank

for source in ["---", "***", "-----"] {
    if !ConversationMarkdown.render(source, style: style).string.contains("\u{2500}") {
        fail("分隔线 \(source) 应该画成横线", "渲染结果里没有 U+2500")
    }
}

// A rule inside a table's separator row must not be mistaken for one.
if ConversationMarkdown.render("| a |\n|---|\n| b |", style: style).string.contains("\u{2500}") {
    fail("表格的分隔行不该被当成水平线")
}

// MARK: - Headings are different sizes

do {
    let rendered = ConversationMarkdown.render("# One\n\n## Two\n\n**Four**", style: style)
    var sizes = [CGFloat]()
    rendered.enumerateAttribute(
        .font, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
        if let font = value as? NSFont, !sizes.contains(font.pointSize) {
            sizes.append(font.pointSize)
        }
    }
    if sizes.count < 3 {
        fail("三级标题应有三种字号", "得到 \(sizes)")
    }
}

// MARK: - Things that are not valid markdown links/images come through unharmed

for text in [
    "<div>Why does this break?</div>",
    "> quoted",
    "~~struck~~",
    "[link] (https://example.com)",
    "[link](https://example.com/a b)",
    "![unclosed](file:///tmp/a.png",
    "[empty]()",
    "[](https://example.com)",
] {
    let rendered = ConversationMarkdown.render(text, style: style).string
    if rendered != text {
        fail("未实现或格式错误的语法应原样显示", "\(text.debugDescription) → \(rendered.debugDescription)")
    }
}

// MARK: - Strict CommonMark links, images, escapes, and nesting

do {
    // 1. Link without `!` pointing to `.png` stays a link, NOT an image.
    let linkToPng = ConversationMarkdown.render(
        "[F01-A](file:///Users/joey/Code/F01-A-smooth-mochi-pads.png)", style: style
    )
    if linkToPng.string != "F01-A" {
        fail("PNG 链接文本错误", linkToPng.string.debugDescription)
    }
    let linkAttr = linkToPng.attribute(.link, at: 0, effectiveRange: nil) as? String
    let imgAttr = linkToPng.attribute(.markdownImage, at: 0, effectiveRange: nil)
    if linkAttr != "file:///Users/joey/Code/F01-A-smooth-mochi-pads.png" || imgAttr != nil {
        fail("无感叹号的 [F01-A](file:///...png) 必须是链接而非图片", "link=\(String(describing: linkAttr)) img=\(String(describing: imgAttr))")
    }

    // 2. Image with `!` emits `.markdownImage`.
    let imageMd = ConversationMarkdown.render(
        "![F01-A](file:///Users/joey/Code/F01-A-smooth-mochi-pads.png)", style: style
    )
    let spec = imageMd.attribute(.markdownImage, at: 0, effectiveRange: nil) as? MarkdownImageSpec
    if imageMd.string != "[F01-A]" || spec != MarkdownImageSpec(alt: "F01-A", destination: "file:///Users/joey/Code/F01-A-smooth-mochi-pads.png") {
        fail("标准图片语法 ![alt](url) 解析错误", "str=\(imageMd.string) spec=\(String(describing: spec))")
    }

    // 3. Nested inline code inside link label: `[`ClassName`](file:///path#L10-L20)`
    let codeLink = ConversationMarkdown.render(
        "[`ClassName`](file:///Users/joey/utils.py#L10-L20)", style: style
    )
    let codeLinkFont = codeLink.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let codeLinkDest = codeLink.attribute(.link, at: 0, effectiveRange: nil) as? String
    if codeLink.string != "ClassName" || codeLinkFont?.isFixedPitch != true || codeLinkDest != "file:///Users/joey/utils.py#L10-L20" {
        fail("行内代码嵌套链接解析错误", "str=\(codeLink.string) fixed=\(String(describing: codeLinkFont?.isFixedPitch)) dest=\(String(describing: codeLinkDest))")
    }

    // 4. Pointy-bracket destination with spaces (`<file:///path with spaces.png>`).
    let angleImg = ConversationMarkdown.render(
        "![shot](<file:///Users/joey/Screenshots/CleanShot 2026-11-11 at 10.53.20@2x.png>)",
        style: style
    )
    let angleSpec = angleImg.attribute(.markdownImage, at: 0, effectiveRange: nil) as? MarkdownImageSpec
    if angleSpec?.destination != "file:///Users/joey/Screenshots/CleanShot 2026-11-11 at 10.53.20@2x.png" {
        fail("尖括号包裹含空格路径解析错误", "spec=\(String(describing: angleSpec))")
    }

    // 5. Balanced parens, escaped parens, escaped brackets, and optional title.
    for (md, expectedText, expectedDest) in [
        ("[wiki](https://en.wikipedia.org/wiki/Foo_(bar))", "wiki", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        (#"[wiki](https://en.wikipedia.org/wiki/Foo_\(bar\))"#, "wiki", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        (#"[a\]b](https://example.com "Title")"#, "a]b", "https://example.com"),
    ] {
        let r = ConversationMarkdown.render(md, style: style)
        let d = r.attribute(.link, at: 0, effectiveRange: nil) as? String
        if r.string != expectedText || d != expectedDest {
            fail("括号/转义/标题链接解析错误: \(md)", "got text=\(r.string.debugDescription) dest=\(String(describing: d))")
        }
    }

    // 6. Backslash-escaped markers do not trigger links or images.
    for (escaped, expectedLiteral) in [
        (#"\[foo](https://example.com)"#, "[foo](https://example.com)"),
        (#"\!\[foo](file:///a.png)"#, "![foo](file:///a.png)"),
    ] {
        let r = ConversationMarkdown.render(escaped, style: style)
        let hasLink = r.attribute(.link, at: 0, effectiveRange: nil) != nil
        let hasImg = r.attribute(.markdownImage, at: 0, effectiveRange: nil) != nil
        if r.string != expectedLiteral || hasLink || hasImg {
            fail("反斜杠转义未生效: \(escaped)", "got \(r.string.debugDescription) link=\(hasLink) img=\(hasImg)")
        }
    }

    // 7. Linked image `[![alt](img.png)](https://example.com)`: inner `.markdownImage`
    //    preserved, outer `.link` wins.
    let linkedImg = ConversationMarkdown.render(
        "[![preview](file:///tmp/preview.png)](https://example.com/full)", style: style
    )
    let liSpec = linkedImg.attribute(.markdownImage, at: 0, effectiveRange: nil) as? MarkdownImageSpec
    let liDest = linkedImg.attribute(.link, at: 0, effectiveRange: nil) as? String
    if liSpec?.destination != "file:///tmp/preview.png" || liDest != "https://example.com/full" {
        fail("链接包裹图片解析错误", "spec=\(String(describing: liSpec)) link=\(String(describing: liDest))")
    }

    // 8. Table alignment holds when cells contain links and images.
    checkTable("含链接与图片的表格仍然严格对齐", """
    | 候选 | 文件 | 说明 |
    |---|---|---|
    | A | [F01-A](file:///Users/joey/Code/F01-A.png) | 圆润触感 |
    | B | ![缩略图](file:///Users/joey/Code/F01-B.png) | 备选方案 |
    """)
}


// MARK: - splitRow agrees with inline about what "inside code" means
//
// Appended after the result block on purpose? No — see below; this runs before
// it because `exit` is the last statement. These are the four inputs review
// gave on 2026-08-02, asserted on the raw cells.

func checkCells(_ name: String, _ row: String, _ expected: [String]) {
    let actual = ConversationMarkdown.splitRow(row)
    if actual != expected {
        fail("splitRow — \(name)", "得到 \(actual)\n      期望 \(expected)")
    }
}

checkCells(
    "REGRESSION 未闭合的反引号是字面字符，不吞掉后面的分隔符",
    "| a ` | b | c |", ["a `", "b", "c"]
)
checkCells(
    "REGRESSION 转义反引号同样不该开启代码区",
    #"| a \` | b | c |"#, [#"a \`"#, "b", "c"]
)
checkCells(
    "REGRESSION 一个闭合的代码区之后又出现未闭合反引号",
    "| `a` | `b | c |", ["`a`", "`b", "c"]
)
checkCells(
    "代码区内的竖线仍然是内容",
    "| `a|b` | c |", ["`a|b`", "c"]
)
checkCells("普通行不受影响", "| a | b | c |", ["a", "b", "c"])
checkCells("空单元格保留", "| a |  | c |", ["a", "", "c"])
checkCells("两个独立代码区", "| `a` | `b` |", ["`a`", "`b`"])

// Whatever splitRow decides, `inline` must agree that the pipes it kept are
// content — otherwise a cell is split somewhere its own renderer would not.
for row in ["| a ` | b |", "| `a|b` | c |", "| `a` | `b | c |"] {
    for cell in ConversationMarkdown.splitRow(row) {
        let rendered = ConversationMarkdown.inline(cell, style: style).string
        let keptPipes = cell.filter { $0 == "|" }.count
        let shownPipes = rendered.filter { $0 == "|" }.count
        if keptPipes != shownPipes {
            fail(
                "splitRow 与 inline 对竖线的判断不一致",
                "\(row.debugDescription) 的一格 \(cell.debugDescription) 保留 \(keptPipes) 个竖线，渲染出 \(shownPipes) 个"
            )
        }
    }
}

// MARK: - Result

if failures == 0 {
    print("MarkdownCheck: all cases pass")
} else {
    print("MarkdownCheck: \(failures) failed")
    exit(1)
}
