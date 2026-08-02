//
//  main.swift
//  StickyOffsetCheck
//
//  Cross-check for `ScrollGeometry`.
//
//      swiftc -O -o /tmp/stickycheck \
//          Attache/UI/ScrollGeometry.swift Tools/StickyOffsetCheck/main.swift
//      /tmp/stickycheck
//
//  **One line of geometry, and getting it wrong is invisible in a
//  screenshot.** The pinned header decides which turn it is showing by
//  comparing cached row positions against the scroll offset. If those
//  positions are off by a row's height, the header simply lags — it still
//  shows *a* prompt, still moves when you scroll, and looks entirely
//  plausible at any single scroll position. It is wrong only in the case the
//  feature exists for: a turn taller than the viewport, where it displays the
//  previous turn's prompt for the whole of it.
//
//  The trap is that the document view is flipped and a row is not, so
//  converting the row's `bounds` *origin* lands on its bottom edge. Shipped
//  that way; found by review 2026-08-02.
//

import AppKit

final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

var failures = 0

func check(_ what: String, _ actual: CGFloat, _ expected: CGFloat) {
    guard abs(actual - expected) > 0.01 else { return }
    failures += 1
    print("FAIL  \(what)")
    print("      expected \(expected), actual \(actual)")
}

// A flipped document with rows laid out downward, which is what the rail is.
let document = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))

// Rows at known tops. In a flipped parent, `frame.origin.y` *is* the top.
let rows: [(top: CGFloat, height: CGFloat, name: String)] = [
    (0, 60, "first row, flush with the top"),
    (60, 250, "a tall turn — the case the header exists for"),
    (310, 44, "a one-line turn"),
    (354, 900, "a turn taller than any viewport"),
    (1254, 60, "last row"),
]

for row in rows {
    let view = NSView(frame: NSRect(x: 0, y: row.top, width: 400, height: row.height))
    document.addSubview(view)
    check(
        row.name,
        ScrollGeometry.topEdge(of: view, in: document),
        row.top
    )
}

// The specific mistake, asserted directly: the old code converted the origin
// point and got the bottom. If `topEdge` ever goes back to that, this fires.
do {
    let view = NSView(frame: NSRect(x: 0, y: 300, width: 400, height: 250))
    document.addSubview(view)
    let top = ScrollGeometry.topEdge(of: view, in: document)
    let bottom = view.convert(NSPoint.zero, to: document).y
    check("REGRESSION top edge, not bottom", top, 300)
    if abs(bottom - 550) > 0.01 {
        failures += 1
        print("FAIL  the premise changed — converting the origin no longer gives 550")
    }
    if abs(top - bottom) < 0.01 {
        failures += 1
        print("FAIL  top and bottom came out equal; this check proves nothing")
    }
}

// MARK: - The real ancestry, not just the convenient one
//
// In the rail a row is not a child of the document — it sits inside an
// NSStackView which sits inside the document. A fixture that skips that layer
// would be checking a view hierarchy the app does not have. `NSStackView` is
// itself *not* flipped, which is exactly the kind of thing that could have
// made the conversion behave differently one level down.

do {
    let document = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: document.topAnchor),
        stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
    ])

    var rows = [NSView]()
    for height in [CGFloat(60), 250, 44, 900] {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows.append(row)
    }
    document.layoutSubtreeIfNeeded()

    var expected: CGFloat = 0
    for (index, row) in rows.enumerated() {
        check(
            "through a stack view — row \(index)",
            ScrollGeometry.topEdge(of: row, in: document),
            expected
        )
        expected += row.frame.height
    }

    // Sorted, which is what the binary search assumes.
    let offsets = rows.map { ScrollGeometry.topEdge(of: $0, in: document) }
    if offsets != offsets.sorted() {
        failures += 1
        print("FAIL  offsets through a stack view are not ascending: \(offsets)")
    }
}

// Offsets have to come out sorted, because the header binary-searches them.
do {
    let sorted = rows.map(\.top)
    if sorted != sorted.sorted() {
        failures += 1
        print("FAIL  the fixture itself is not in order")
    }
}

// The search the pinned header runs on every scroll.
do {
    let offsets: [CGFloat] = [0, 60, 310, 354, 1254]
    let cases: [(CGFloat, Int?)] = [
        (-1, nil),          // above everything
        (0, 0),             // exactly the first
        (59, 0),
        (60, 1),            // exactly a boundary
        (309, 1),
        (1254, 4),
        (99999, 4),         // past the end
    ]
    for (position, expected) in cases {
        let actual = ScrollGeometry.lastIndex(atOrAbove: position, in: offsets)
        if actual != expected {
            failures += 1
            print("FAIL  二分查找 position=\(position)")
            print("      expected \(String(describing: expected)), actual \(String(describing: actual))")
        }
    }
    if ScrollGeometry.lastIndex(atOrAbove: 0, in: []) != nil {
        failures += 1
        print("FAIL  空数组应返回 nil")
    }
}

// Duplicate offsets cannot reach the search — `areUsable` rejects them — but
// the search's behaviour on them is pinned anyway, because "which of the two
// wins" is the difference between a header that sits still and one that
// flickers between two turns on every scroll event.
do {
    let withDuplicates: [CGFloat] = [0, 60, 60, 60, 310]
    let picked = ScrollGeometry.lastIndex(atOrAbove: 100, in: withDuplicates)
    if picked != 3 {
        failures += 1
        print("FAIL  重复偏移应确定性地选中最后一个，得到 \(String(describing: picked))")
    }
    // Same input, asked repeatedly: the answer must not move.
    let answers = (0..<20).map { _ in
        ScrollGeometry.lastIndex(atOrAbove: 100, in: withDuplicates)
    }
    if Set(answers.map { $0 ?? -1 }).count != 1 {
        failures += 1
        print("FAIL  同样的输入给出了不同的答案，悬浮标题会闪烁")
    }
}


// MARK: - Refusing offsets taken before layout ran
//
// Observed live 2026-08-02: sixteen turns all reporting 30126 in a 30126pt
// document, right after a rebuild. Cached, that set strands the pinned header
// permanently — the staleness test only watches width and height, both of
// which match.

for (offsets, usable, note) in [
    ([CGFloat(0), 60, 310], true, "正常递增"),
    ([CGFloat(4)], true, "只有一轮"),
    ([], false, "空"),
    ([CGFloat(30126), 30126, 30126], false, "REGRESSION 布局未完成，全部塌成同一个值"),
    ([CGFloat(0), 0, 310], false, "前两个相同"),
    ([CGFloat(0), 310, 60], false, "顺序颠倒"),
] as [([CGFloat], Bool, String)] {
    if ScrollGeometry.areUsable(offsets) != usable {
        failures += 1
        print("FAIL  areUsable — \(note)")
        print("      \(offsets) 期望 \(usable)")
    }
}

if failures == 0 {
    print("StickyOffsetCheck: 全部通过（含布局未完成的防护）")
} else {
    print("StickyOffsetCheck: \(failures) failed")
    exit(1)
}
