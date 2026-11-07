//
//  MarkdownTextView.swift
//  Attache
//

import Cocoa

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

extension NSAttributedString.Key {
    static let markdownDecoration = NSAttributedString.Key("AttacheMarkdownDecoration")
}

/// Draws the `MarkdownDecoration`s under the text it lays out.
private final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // The decorations first and the selection after: the other way
        // round, a code box's fill covered the highlight, and text selected
        // in a code block showed no sign of it.
        defer { super.drawBackground(forGlyphRange: glyphsToShow, at: origin) }
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var drawn = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.markdownDecoration, in: characters) { value, shown, _ in
            guard let decoration = value as? MarkdownDecoration,
                  drawn.insert(ObjectIdentifier(decoration)).inserted else { return }
            // The whole run, not the part being redrawn: a box drawn round
            // half a code block is a box in the wrong place.
            var range = NSRange()
            _ = storage.attribute(.markdownDecoration, at: shown.location, longestEffectiveRange: &range,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            draw(decoration, glyphs: glyphs, container: container, origin: origin,
                 lineSpacing: (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                     as? NSParagraphStyle)?.lineSpacing ?? 0)
        }
    }

    private func draw(_ decoration: MarkdownDecoration, glyphs: NSRange, container: NSTextContainer,
                      origin: NSPoint, lineSpacing: CGFloat) {
        // Every line the run is on: the full fragment (spacing included, so
        // consecutive items' guides join up) and the used part (the glyphs).
        var fragments: [(rect: NSRect, used: NSRect)] = []
        enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
            fragments.append((rect.offsetBy(dx: origin.x, dy: origin.y), used.offsetBy(dx: origin.x, dy: origin.y)))
        }
        guard let first = fragments.first, let last = fragments.last else { return }
        decoration.colour.setFill()
        switch decoration.kind {
        case .headingBar:
            // The glyphs' own height: the line spacing below the last line is
            // air, not heading.
            let top = first.used.minY + 1
            let bottom = last.used.maxY - lineSpacing - 1
            NSBezierPath(roundedRect: NSRect(x: origin.x, y: top, width: 3, height: max(0, bottom - top)),
                         xRadius: 1.5, yRadius: 1.5).fill()
        case .guide(let x):
            NSRect(x: origin.x + x, y: first.rect.minY, width: 1.5, height: last.rect.maxY - first.rect.minY).fill()
            let middle = first.used.minY + (first.used.height - lineSpacing) / 2
            NSRect(x: origin.x + x, y: middle - 0.75, width: 7, height: 1.5).fill()
        case .disc(let radius):
            let glyphRect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let centre = NSPoint(x: glyphRect.midX, y: first.used.minY + (first.used.height - lineSpacing) / 2)
            NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        case .codeBox(let padding, let stroke):
            let box = NSRect(x: origin.x + 0.5, y: first.used.minY - padding,
                             width: container.size.width - 1,
                             height: last.used.maxY - lineSpacing - first.used.minY + padding * 2)
            let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Copies without the hairline paragraph a reply that opens with a code block
/// starts with (`ConversationMarkdown.render`): it is spacing, not text.
private final class ReplyTextView: NSTextView {
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.location == 0, range.length > 1, let storage = textStorage,
              storage.string.hasPrefix("\n") else {
            return super.writeSelection(to: pboard, types: types)
        }
        let text = storage.attributedSubstring(from: NSRange(location: 1, length: range.length - 1))
        pboard.clearContents()
        return pboard.writeObjects([text])
    }
}

/// Rendered markdown, selectable, at the height its width gives it, with the
/// decorations `ConversationMarkdown` asks for drawn under it.
///
/// A text view rather than a label: a label draws an attributed string and
/// nothing else, and the decorations need a layout manager to ask where each
/// line went.
final class MarkdownTextView: NSView {
    private let storage: NSTextStorage
    private let manager = MarkdownLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    private let text: NSTextView
    private var measuredWidth: CGFloat = -1
    private var height: CGFloat = 0
    private var bottomInset: CGFloat = 0

    init(_ string: NSAttributedString) {
        storage = NSTextStorage(attributedString: string)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        text = ReplyTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        // A code box last reaches its padding below the text: its spacing
        // after went with the trailing newline. (One first is given a
        // paragraph above it by the renderer, since the text view clips
        // drawing to its container and an inset there would cut the box.)
        if string.length > 0,
           let d = string.attribute(.markdownDecoration, at: string.length - 1, effectiveRange: nil)
               as? MarkdownDecoration,
           case .codeBox(let padding, _) = d.kind {
            bottomInset = padding + 1
        }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.isAutomaticLinkDetectionEnabled = false
        addSubview(text)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if width != measuredWidth, width > 0 {
            measuredWidth = width
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let measured = ceil(manager.usedRect(for: container).height + bottomInset)
            if measured != height {
                height = measured
                invalidateIntrinsicContentSize()
            }
        }
        text.frame = NSRect(x: 0, y: 0, width: width, height: max(height, bounds.height))
    }
}
