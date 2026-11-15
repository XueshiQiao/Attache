//
//  GuardChips.swift
//  Attache
//

import AppKit

/// Placeholders the privacy guard put in a conversation (`⟦ip:7f3a9c⟧`),
/// drawn as chips, and clicked to show the real value on this screen.
///
/// The placeholder's own text is kept, only restyled: copying a reply and
/// pasting it back to the agent has to carry the placeholder, which the
/// guard turns back into the value when a command runs. A chip that read
/// "IP · 7f3a" would paste as words nothing can put back.
enum GuardChips {
    static let scheme = "attache-guard:"

    private static let pattern = try? NSRegularExpression(pattern: #"⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧"#)

    static func decorate(_ text: NSMutableAttributedString, style: ConversationMarkdown.Style) {
        guard let pattern, text.string.contains("⟦") else { return }
        let whole = NSRange(location: 0, length: text.length)
        let tint = style.accent.withAlphaComponent(0.16)
        for match in pattern.matches(in: text.string, range: whole).reversed() {
            let token = (text.string as NSString).substring(with: match.range)
            let size = (text.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont)?.pointSize
                ?? style.body.pointSize
            text.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(9, size - 1.5), weight: .medium),
                .backgroundColor: tint,
                .foregroundColor: style.accent,
                .link: (scheme + token) as NSString,
                .toolTip: "A private value the privacy guard kept from the model. Click to show it here.",
            ], range: match.range)
        }
    }

    /// Shows the value behind a clicked chip in a popover, read from the
    /// conversation's own host. False when the link is not a chip's.
    @MainActor
    static func handleClick(_ link: Any, in view: NSTextView, at index: Int, cli: AttacheCliLink?) -> Bool {
        guard let raw = ChatLinkContext.linkTargetString(from: link), raw.hasPrefix(scheme) else { return false }
        let token = String(raw.dropFirst(scheme.count))
        guard let argv = GuardCommands.reveal([token]) else { return true }
        let anchor = rect(of: index, in: view)
        guard let cli else {
            show("This conversation's host cannot be asked from here.", token: token, from: anchor, in: view)
            return true
        }
        cli.run(argv) { lines in
            let o = GuardCommands.object(lines)
            if let value = (o?["values"] as? [String: String])?[token] {
                show(value, token: token, from: anchor, in: view, isValue: true)
            } else {
                show(o?["why"] as? String ?? "This host's vault has no value for it (made on another host, or forgotten).",
                     token: token, from: anchor, in: view)
            }
        }
        return true
    }

    @MainActor
    private static func rect(of index: Int, in view: NSTextView) -> NSRect {
        guard let manager = view.layoutManager, let container = view.textContainer else { return view.bounds }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var r = manager.boundingRect(forGlyphRange: glyphs, in: container)
        r.origin.x += view.textContainerOrigin.x
        r.origin.y += view.textContainerOrigin.y
        return r
    }

    @MainActor
    private static func show(_ text: String, token: String, from rect: NSRect, in view: NSView, isValue: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = isValue ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 12)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 360
        let caption = NSTextField(labelWithString: token)
        caption.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        caption.textColor = .secondaryLabelColor
        var views: [NSView] = [caption, label]
        if isValue {
            let copy = NSButton(title: "Copy", target: nil, action: nil)
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            let handler = CopyAction(text)
            copy.target = handler
            copy.action = #selector(CopyAction.copyValue)
            objc_setAssociatedObject(copy, &CopyAction.key, handler, .OBJC_ASSOCIATION_RETAIN)
            views.append(copy)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private final class CopyAction: NSObject {
        nonisolated(unsafe) static var key = 0
        let text: String
        init(_ text: String) { self.text = text }
        @objc func copyValue() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
