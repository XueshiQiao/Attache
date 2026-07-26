//
//  TmuxLayout.swift
//  TmuxGUI
//

import Foundation

/// Where a node sits inside its window, in tmux's character grid.
///
/// tmux counts the divider between two siblings as one cell, so children do
/// not tile their parent exactly: a 276-column window split left/right gives
/// children of 138 and 137 columns at x=0 and x=139. Reproducing the gap is
/// what keeps the GUI's splitters lined up with tmux's idea of the layout.
struct TmuxLayoutFrame: Equatable {
    var columns: Int
    var rows: Int
    var x: Int
    var y: Int
}

/// One node of a parsed tmux window layout.
indirect enum TmuxLayoutNode: Equatable {
    /// A single pane. `paneID` is the full tmux id including the `%`.
    case pane(id: String, frame: TmuxLayoutFrame)
    /// Children arranged left to right — tmux writes these with `{}`.
    case leftRight(children: [TmuxLayoutNode], frame: TmuxLayoutFrame)
    /// Children arranged top to bottom — tmux writes these with `[]`.
    case topBottom(children: [TmuxLayoutNode], frame: TmuxLayoutFrame)

    var frame: TmuxLayoutFrame {
        switch self {
        case .pane(_, let frame), .leftRight(_, let frame), .topBottom(_, let frame):
            frame
        }
    }

    var children: [TmuxLayoutNode] {
        switch self {
        case .pane: []
        case .leftRight(let children, _), .topBottom(let children, _): children
        }
    }

    /// Every pane in the tree, in tmux's own order.
    var panes: [(id: String, frame: TmuxLayoutFrame)] {
        switch self {
        case .pane(let id, let frame):
            [(id, frame)]
        case .leftRight(let children, _), .topBottom(let children, _):
            children.flatMap(\.panes)
        }
    }
}

enum TmuxLayoutError: Error, CustomStringConvertible {
    case malformed(String, at: Int)

    var description: String {
        switch self {
        case .malformed(let reason, let offset):
            "布局字符串在第 \(offset) 个字符处解析失败：\(reason)"
        }
    }
}

/// Parser for tmux's `window_layout` format.
///
/// Grammar, as observed on tmux 3.6a:
///
///     layout   := checksum "," node
///     node     := WxH "," x "," y ( "," paneNumber | "{" list "}" | "[" list "]" )
///     list     := node ( "," node )*
///
/// The leading four hex digits are tmux's own checksum over the rest. It only
/// matters when *writing* a layout back with `select-layout`; this app changes
/// layouts with `resize-pane` and `split-window` instead, so the checksum is
/// checked for shape and then ignored.
enum TmuxLayout {
    static func parse(_ text: String) throws -> TmuxLayoutNode {
        var parser = Parser(Array(text.utf8))
        try parser.expectChecksum()
        let node = try parser.parseNode()
        guard parser.atEnd else {
            throw TmuxLayoutError.malformed("末尾有多余内容", at: parser.offset)
        }
        return node
    }

    private struct Parser {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { offset >= bytes.count }

        private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

        mutating func expectChecksum() throws {
            // Four hex digits then a comma. Not validated as a checksum — see
            // the note on the enum.
            guard bytes.count > 5, bytes[4] == UInt8(ascii: ",") else {
                throw TmuxLayoutError.malformed("开头不是「四位校验和 + 逗号」", at: 0)
            }
            offset = 5
        }

        mutating func parseNode() throws -> TmuxLayoutNode {
            let columns = try parseInt()
            try expect(UInt8(ascii: "x"), "宽高之间应该是 x")
            let rows = try parseInt()
            try expect(UInt8(ascii: ","), "高度后应该是逗号")
            let x = try parseInt()
            try expect(UInt8(ascii: ","), "x 坐标后应该是逗号")
            let y = try parseInt()
            let frame = TmuxLayoutFrame(columns: columns, rows: rows, x: x, y: y)

            switch current {
            case UInt8(ascii: ","):
                // Leaf: the trailing number is the pane id without its `%`.
                offset += 1
                let paneNumber = try parseInt()
                return .pane(id: "%\(paneNumber)", frame: frame)

            case UInt8(ascii: "{"):
                return .leftRight(
                    children: try parseChildren(close: UInt8(ascii: "}")),
                    frame: frame
                )

            case UInt8(ascii: "["):
                return .topBottom(
                    children: try parseChildren(close: UInt8(ascii: "]")),
                    frame: frame
                )

            default:
                throw TmuxLayoutError.malformed("几何之后应该是 , 或 { 或 [", at: offset)
            }
        }

        private mutating func parseChildren(close: UInt8) throws -> [TmuxLayoutNode] {
            offset += 1 // opening bracket
            var children = [TmuxLayoutNode]()
            while true {
                children.append(try parseNode())
                guard let byte = current else {
                    throw TmuxLayoutError.malformed("括号没有闭合", at: offset)
                }
                if byte == close {
                    offset += 1
                    break
                }
                guard byte == UInt8(ascii: ",") else {
                    throw TmuxLayoutError.malformed("子节点之间应该是逗号", at: offset)
                }
                offset += 1
            }
            guard children.count >= 2 else {
                throw TmuxLayoutError.malformed("容器节点至少要有两个子节点", at: offset)
            }
            return children
        }

        private mutating func parseInt() throws -> Int {
            let start = offset
            var value = 0
            while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
                offset += 1
            }
            guard offset > start else {
                throw TmuxLayoutError.malformed("这里应该是一个数字", at: start)
            }
            return value
        }

        private mutating func expect(_ byte: UInt8, _ reason: String) throws {
            guard current == byte else {
                throw TmuxLayoutError.malformed(reason, at: offset)
            }
            offset += 1
        }
    }
}
