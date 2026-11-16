//
//  GuardChips.swift
//  Attache
//

import AppKit

extension NSAttributedString.Key {
    /// The placeholder a run of text stands for: on a chip, its own text; on
    /// a value put back for this screen, what the model saw instead.
    static let guardToken = NSAttributedString.Key("AttacheGuardToken")
}

/// Placeholders the privacy guard put in a conversation (`⟦ip:7f3a9c⟧`),
/// shown on this screen as the real value, on a tint, with the placeholder
/// in its tooltip — the owner's choice on 2026-11-16, as is copying the
/// value rather than the placeholder.
///
/// Rendering is cached and knows no host, so it only marks each placeholder
/// as a chip (`decorate`); the view that shows the text knows its host and
/// swaps in the values it can get (`hydrate` for a text view, `bind` for a
/// label). A placeholder the host has no value for stays a chip, and a
/// click on it says why.
enum GuardChips {
    static let scheme = "attache-guard:"

    private static let pattern = try? NSRegularExpression(pattern: #"⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧"#)

    static func decorate(_ text: NSMutableAttributedString, style: ConversationMarkdown.Style) {
        decorate(text, accent: style.accent, size: style.body.pointSize)
    }

    static func decorate(_ text: NSMutableAttributedString, accent: NSColor, size fallback: CGFloat) {
        guard let pattern, text.string.contains("⟦") else { return }
        let whole = NSRange(location: 0, length: text.length)
        let tint = accent.withAlphaComponent(0.16)
        for match in pattern.matches(in: text.string, range: whole).reversed() {
            if text.attribute(.guardToken, at: match.range.location, effectiveRange: nil) != nil { continue }
            let token = (text.string as NSString).substring(with: match.range)
            let font = text.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? fallback
            var attributes: [NSAttributedString.Key: Any] = [
                // Already monospaced (code, output, a diff): the same size as
                // the code around it.
                .font: font?.isFixedPitch == true ? font! : NSFont.monospacedSystemFont(ofSize: max(9, size - 1.5), weight: .medium),
                .backgroundColor: tint,
                .foregroundColor: accent,
                .guardToken: token,
                .toolTip: "A private value the privacy guard kept from the model. Click to see why it is not shown.",
            ]
            // Inside a link's text, the link stays the link.
            if text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                attributes[.link] = (scheme + token) as NSString
            }
            text.addAttributes(attributes, range: match.range)
        }
    }

    /// Puts back, in `text`, every value this host's vault gave. Returns the
    /// placeholders still without one.
    @MainActor
    static func reveal(_ text: NSMutableAttributedString, values: GuardValues) -> [String] {
        guard let pattern, text.string.contains("⟦") else { return [] }
        var missing: [String] = []
        for match in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let token = (text.string as NSString).substring(with: match.range)
            guard let value = values.value(token) else {
                if !missing.contains(token) { missing.append(token) }
                continue
            }
            var attributes = text.attributes(at: match.range.location, effectiveRange: nil)
            if let link = attributes[.link].flatMap(ChatLinkContext.linkTargetString(from:)), link.hasPrefix(scheme) {
                attributes[.link] = nil
            }
            attributes[.guardToken] = token
            attributes[.toolTip] = "The model saw \(token). The privacy guard shows the real value on this screen only."
            text.replaceCharacters(in: match.range, with: NSAttributedString(string: value, attributes: attributes))
        }
        return missing
    }

    /// A text view's storage: values swapped in now where known, and as they
    /// arrive otherwise, with `onAsyncUpdate` after each later change.
    @MainActor
    static func hydrate(_ storage: NSTextStorage, cli: AttacheCliLink?,
                        onAsyncUpdate: @escaping @MainActor () -> Void) {
        guard let cli, storage.string.contains("⟦") else { return }
        let values = GuardValues.shared(for: cli)
        storage.beginEditing()
        let missing = reveal(storage, values: values)
        storage.endEditing()
        guard !missing.isEmpty else { return }
        values.want(missing) { [weak storage] learned in
            guard learned, let storage else { return }
            hydrate(storage, cli: cli, onAsyncUpdate: onAsyncUpdate)
            onAsyncUpdate()
        }
    }

    /// What a label is bound to, kept on the label: many labels are reused
    /// for one text after another (the rail's pinned prompt, the docks, the
    /// working line) and some are set many times a second, so an answer
    /// must find out whether the label still wants it, and a label waits on
    /// at most one ask per host.
    @MainActor
    private final class Binding {
        nonisolated(unsafe) static var key = 0
        var cli: AttacheCliLink?
        var waitingOn: AttacheCliLink?
        // The latest of each, so an answer redraws the label as it was last
        // asked for, not as it was when the ask went out.
        var accent: NSColor?
        var onAsyncUpdate: (@MainActor () -> Void)?
    }

    /// `text` with every value this host's vault gave put back, as plain
    /// text: for the places that take a string, such as an alert.
    @MainActor
    static func revealed(_ text: String, cli: AttacheCliLink?) -> String {
        guard let cli, text.contains("⟦") else { return text }
        let out = NSMutableAttributedString(string: text)
        _ = reveal(out, values: GuardValues.shared(for: cli))
        return out.string
    }

    /// A label: its placeholders marked as chips, and the values swapped in
    /// as `hydrate` does. Call again whenever its text is set.
    @MainActor
    static func bind(_ field: NSTextField, cli: AttacheCliLink?, accent: NSColor? = nil,
                     onAsyncUpdate: (@MainActor () -> Void)? = nil) {
        let binding = (objc_getAssociatedObject(field, &Binding.key) as? Binding) ?? {
            let made = Binding()
            objc_setAssociatedObject(field, &Binding.key, made, .OBJC_ASSOCIATION_RETAIN)
            return made
        }()
        binding.cli = cli
        binding.accent = accent
        binding.onAsyncUpdate = onAsyncUpdate
        guard field.stringValue.contains("⟦") else { return }
        let text = NSMutableAttributedString(attributedString: field.attributedStringValue)
        decorate(text, accent: accent ?? ChromeTheme.current.accent, size: field.font?.pointSize ?? 13)
        let values = cli.map(GuardValues.shared(for:))
        // With no host to ask, every placeholder is one still without a value.
        let missing = values.map { reveal(text, values: $0) } ?? tokens(in: text.string)
        // A label has no click for a chip (only the text views do), so one
        // still without a value says why on hover instead of promising one,
        // and is not a link a click would hand to the system.
        if !missing.isEmpty {
            text.enumerateAttribute(.guardToken, in: NSRange(location: 0, length: text.length)) { v, range, _ in
                guard let token = v as? String, missing.contains(token) else { return }
                // Only the chip's own link: a placeholder can be a real link's text.
                if let link = text.attribute(.link, at: range.location, effectiveRange: nil)
                    .flatMap(ChatLinkContext.linkTargetString(from:)), link.hasPrefix(scheme) {
                    text.removeAttribute(.link, range: range)
                }
                text.addAttribute(.toolTip, value: "A private value the privacy guard kept from the model. "
                    + (cli == nil ? "There is no host to ask for it here."
                       : "This host has no value for it (made on another host, or forgotten), or did not answer."),
                    range: range)
            }
        }
        // A selectable label that may not keep attributes drops them the
        // moment it is clicked, tint and all.
        if field.isSelectable { field.allowsEditingTextAttributes = true }
        field.attributedStringValue = text
        guard let cli, let values, !missing.isEmpty, binding.waitingOn != cli else { return }
        guard values.want(missing, then: { [weak field, weak binding] learned in
            guard let binding, binding.waitingOn == cli else { return }
            binding.waitingOn = nil
            // Bound since to another host's text: that binding asks for itself.
            // Otherwise bound again even when nothing was learned, since the
            // label may hold placeholders this ask did not carry; those just
            // asked are not asked again for a while, so this ends.
            guard let field, binding.cli == cli else { return }
            let before = field.stringValue
            bind(field, cli: cli, accent: binding.accent, onAsyncUpdate: binding.onAsyncUpdate)
            // Changed by a value another view's ask brought, too.
            guard field.stringValue != before else { return }
            field.invalidateIntrinsicContentSize()
            binding.onAsyncUpdate?()
        }) else { return }
        binding.waitingOn = cli
    }

    private static func tokens(in text: String) -> [String] {
        guard let pattern else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { (text as NSString).substring(with: $0.range) }
    }

    /// A label's text, once set as attributes, carries the line-break mode
    /// it had then (measured: a label's `attributedStringValue` holds a
    /// paragraph style with it), so a later change to the label's own mode —
    /// "Show all" — would not reach it. This carries the new mode over.
    @MainActor
    static func followLineBreak(_ field: NSTextField) {
        let text = NSMutableAttributedString(attributedString: field.attributedStringValue)
        let whole = NSRange(location: 0, length: text.length)
        var marked = false
        text.enumerateAttribute(.guardToken, in: whole) { v, _, stop in if v != nil { marked = true; stop.pointee = true } }
        guard marked else { return }
        text.enumerateAttribute(.paragraphStyle, in: whole) { v, range, _ in
            let style = ((v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.lineBreakMode = field.lineBreakMode
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        field.attributedStringValue = text
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
