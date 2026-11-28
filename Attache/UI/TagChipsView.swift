//
//  TagChipsView.swift
//  Attache
//

import AppKit

/// The colour each tag colour name is drawn in. The names are attache-cli's
/// (`TagCommands.colors`), so the phone draws the same tag in the same hue.
enum TagPalette {
    static func color(_ name: String) -> NSColor {
        switch name {
        case "red": NSColor(srgbRed: 0.91, green: 0.30, blue: 0.27, alpha: 1)
        case "orange": NSColor(srgbRed: 0.95, green: 0.55, blue: 0.20, alpha: 1)
        case "yellow": NSColor(srgbRed: 0.93, green: 0.77, blue: 0.18, alpha: 1)
        case "green": NSColor(srgbRed: 0.30, green: 0.73, blue: 0.38, alpha: 1)
        case "teal": NSColor(srgbRed: 0.18, green: 0.70, blue: 0.70, alpha: 1)
        case "blue": NSColor(srgbRed: 0.27, green: 0.53, blue: 0.95, alpha: 1)
        case "purple": NSColor(srgbRed: 0.62, green: 0.42, blue: 0.90, alpha: 1)
        case "pink": NSColor(srgbRed: 0.93, green: 0.40, blue: 0.67, alpha: 1)
        default: NSColor(srgbRed: 0.60, green: 0.62, blue: 0.66, alpha: 1)
        }
    }

    /// A menu item's title with a dot in the colour in front of it.
    ///
    /// In the title, not in `image`: measured on macOS 27.0.1 with a probe
    /// app, a context menu draws no item image at all — a drawn image, a
    /// bitmap and a tinted SF Symbol all came out as blank space — while a
    /// coloured character in an attributed title shows. The first version
    /// set `image` and every tag in every menu was colourless.
    static func menuTitle(_ text: String, color name: String, font: NSFont = .menuFont(ofSize: 0)) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "●  ", attributes: [.foregroundColor: color(name), .font: font]
        )
        title.append(NSAttributedString(string: text, attributes: [.font: font]))
        return title
    }
}

/// A window's tags on its rail row: a small chip each, a coloured dot and
/// the name.
///
/// The name is drawn in the rail's own text colour and the colour lives in
/// the dot alone. A tag's colour is fixed and the scheme under it is any of
/// 485, so text in the tag's colour would be yellow on cream somewhere; the
/// dot only has to be seen, not read. When the row is too narrow for the
/// names the chips give way to bare dots, which still say which tags are
/// there — the tooltip names them.
///
/// Plain layer-backed subviews and no `draw(_:)`, for the macOS 26
/// sibling-overdraw reason in AGENTS.md.
final class TagChipsView: NSView {
    private static let chipHeight: CGFloat = 14
    private static let dotSize: CGFloat = 6
    private static let gap: CGFloat = 3
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .medium)

    private var tags: [WindowTag] = []
    private var chips: [(box: NSView, dot: NSView, label: NSTextField)] = []
    private var compact = false
    private var chipFill: CGColor?

    override var isFlipped: Bool { true }

    var isEmpty: Bool { tags.isEmpty }

    func show(_ tags: [WindowTag], onAccent: Bool) {
        self.tags = tags
        chips.forEach { $0.box.removeFromSuperview() }
        chips = tags.map { tag in
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 4
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Self.dotSize / 2
            // On the selected row every colour is a tint of `onAccent`, as
            // everything else on that row is: a hue over the accent fill
            // fights it and neither reads. The names still say which tag.
            dot.layer?.backgroundColor = onAccent
                ? ChromeTheme.current.onAccent.withAlphaComponent(0.9).cgColor
                : TagPalette.color(tag.color).cgColor
            let label = NSTextField(labelWithString: tag.name)
            label.font = Self.font
            label.lineBreakMode = .byClipping
            label.isSelectable = false
            label.refusesFirstResponder = true
            box.addSubview(dot)
            box.addSubview(label)
            addSubview(box)
            return (box, dot, label)
        }
        let theme = ChromeTheme.current
        chipFill = (onAccent ? theme.onAccent : theme.text).withAlphaComponent(0.10).cgColor
        for chip in chips {
            chip.label.textColor = onAccent ? theme.onAccent : theme.mutedText
        }
        isHidden = tags.isEmpty
        needsLayout = true
    }

    private func chipWidth(_ index: Int) -> CGFloat {
        let text = ceil(chips[index].label.attributedStringValue.size().width)
        return 4 + Self.dotSize + 3 + text + 5
    }

    /// The width the chips take at their full size.
    var fullWidth: CGFloat {
        guard !chips.isEmpty else { return 0 }
        return chips.indices.reduce(0) { $0 + chipWidth($1) } + Self.gap * CGFloat(chips.count - 1)
    }

    /// The width bare dots take.
    var compactWidth: CGFloat {
        guard !chips.isEmpty else { return 0 }
        return CGFloat(chips.count) * Self.dotSize + Self.gap * CGFloat(chips.count - 1)
    }

    /// How wide this will be given at most `available`, choosing chips or
    /// dots; set `frame` to that width afterwards.
    func fit(_ available: CGFloat) -> CGFloat {
        if fullWidth <= available {
            compact = false
            return fullWidth
        }
        compact = true
        return min(compactWidth, max(0, available))
    }

    static var height: CGFloat { chipHeight }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (index, chip) in chips.enumerated() {
            if compact {
                chip.box.layer?.backgroundColor = NSColor.clear.cgColor
                chip.label.isHidden = true
                chip.box.frame = CGRect(x: x, y: 0, width: Self.dotSize, height: bounds.height)
                chip.dot.frame = CGRect(
                    x: 0, y: (bounds.height - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize
                )
                x += Self.dotSize + Self.gap
            } else {
                let width = chipWidth(index)
                chip.box.layer?.backgroundColor = chipFill
                chip.label.isHidden = false
                chip.box.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
                chip.dot.frame = CGRect(
                    x: 4, y: (bounds.height - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize
                )
                let textHeight: CGFloat = 12
                chip.label.frame = CGRect(
                    x: 4 + Self.dotSize + 3, y: (bounds.height - textHeight) / 2,
                    width: width - (4 + Self.dotSize + 3), height: textHeight
                )
                x += width + Self.gap
            }
        }
    }
}
