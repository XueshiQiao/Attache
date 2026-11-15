//
//  MermaidDiagram.swift
//  Attache
//

import AppKit

/// A fenced ```` ```mermaid ```` block in rendered markdown: the run it is on
/// is the block drawn as code, which is what stays on screen until — and
/// unless — a picture of it arrives.
///
/// A class, compared by identity, for the reason `MarkdownDecoration` is one:
/// two equal diagrams one after the other must stay two runs.
final class MarkdownDiagramSpec: NSObject {
    let source: String

    init(source: String) {
        self.source = source
    }
}

/// One diagram that has a picture, in one text storage: both things it can
/// be shown as. The run it is on is either of them, and a click swaps.
private final class MermaidDiagramShown: NSObject {
    let image: NSImage
    /// The block as code, as it was before the picture replaced it.
    let code: NSAttributedString

    init(image: NSImage, code: NSAttributedString) {
        self.image = image
        self.code = code
    }
}

extension NSAttributedString.Key {
    static let markdownDiagram = NSAttributedString.Key("AttacheMarkdownDiagram")
    static let markdownDiagramToken = NSAttributedString.Key("AttacheMarkdownDiagramToken")
    /// On a diagram that has a picture, over the whole of whichever form is
    /// showing: the picture, or its code and the line under it.
    static let markdownDiagramShown = NSAttributedString.Key("AttacheMarkdownDiagramShown")
}

/// Turns `.markdownDiagram` runs into pictures.
///
/// **attache-cli draws; this shows a PNG.** No web view is involved and none
/// may be (CLAUDE.md): the first version loaded attache-cli's SVG into one,
/// and the owner threw it out.
///
/// **When a diagram is asked for is the whole design, so here it is in one
/// place.** A block is a diagram only once its closing fence has arrived
/// (`ConversationMarkdown.parse`), so a reply still being written is never
/// drawn half-made, once per token. Then, for a block in a view being built:
///
/// - kept in memory → the picture, at once;
/// - refused before → stays code, nothing asked;
/// - otherwise it stays code while the PNG is read from disk or, failing
///   that, asked of attache-cli on the session's host, and swapped in when
///   the picture exists.
///
/// Every failure leaves the block exactly as it was before this feature: the
/// source, as code. What differs is what is remembered. attache-cli refusing
/// the source is remembered for the life of the app; no answer at all is
/// remembered for half a minute, so a dead link is not asked on every redraw
/// and a live one gets another chance (`MermaidCommand.Answer`).
///
/// The PNG is kept on disk under a hash of the source, the theme and the
/// scale, so a diagram is drawn once: a conversation reopened tomorrow, or
/// with the host unreachable, shows the pictures it showed before.
@MainActor
enum MermaidDiagramLoader {
    /// Wider than an image's budget: a diagram shrunk to a photo's 360pt of
    /// height has text nobody can read.
    static let maxSize = NSSize(width: 760, height: 1100)

    private final class Entry: NSObject {
        let image: NSImage
        init(image: NSImage) { self.image = image }
    }

    private static let images: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        return cache
    }()
    private static var refused = Set<String>()
    private static var unanswered = [String: Date]()
    private static var waiting = [String: [(NSImage?) -> Void]]()

    /// At most this many `attache-cli mermaid` at once: opening a long
    /// conversation is not thirty ssh execs in the same instant.
    private static let maxAsking = 2
    private static var asking = 0
    private static var queued = [() -> Void]()

    private static let retryAfter: TimeInterval = 30

    /// What a click on "Show diagram" is a link to. Never opened: the text
    /// view's delegate hands it here first.
    private static let showLink = "attache-diagram:show"

    /// Pixels per point asked of attache-cli. The main screen's, as a whole
    /// number: a picture drawn for a Retina screen is fine on a plain one,
    /// and the other way round is the blur this avoids.
    private static var scale: Int {
        min(3, max(1, Int((NSScreen.screens.map(\.backingScaleFactor).max() ?? 2).rounded(.up))))
    }

    static func hydrate(_ storage: NSTextStorage, context: ChatLinkContext,
                        onAsyncUpdate: @escaping @MainActor () -> Void) {
        guard let cli = context.cli, storage.length > 0 else { return }
        var runs = [(spec: MarkdownDiagramSpec, range: NSRange)]()
        storage.enumerateAttribute(.markdownDiagram, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let spec = value as? MarkdownDiagramSpec { runs.append((spec, range)) }
        }
        guard !runs.isEmpty else { return }

        let scale = scale
        var pending = [(token: NSString, spec: MarkdownDiagramSpec, dark: Bool, key: String)]()
        storage.beginEditing()
        for (spec, range) in runs.reversed() {
            let dark = isLight(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
            let key = MermaidCommand.key(source: spec.source, dark: dark, scale: scale)
            if let entry = images.object(forKey: key as NSString) {
                showPicture(entry.image, in: storage, replacing: range)
            } else if !refused.contains(key) {
                let token = UUID().uuidString as NSString
                storage.addAttribute(.markdownDiagramToken, value: token, range: range)
                pending.append((token, spec, dark, key))
            }
        }
        storage.endEditing()

        for item in pending {
            load(key: item.key, source: item.spec.source, dark: item.dark, scale: scale, cli: cli) { [weak storage] image in
                guard let storage, let image, let range = find(item.token, in: storage) else { return }
                storage.beginEditing()
                showPicture(image, in: storage, replacing: range)
                storage.endEditing()
                onAsyncUpdate()
            }
        }
    }

    /// A click on a drawn diagram shows its source, as the code block it
    /// was, with a "Show diagram" line under it that brings the picture
    /// back. True when the click was on a diagram.
    static func handleClick(in textView: NSTextView, at index: Int) -> Bool {
        guard let storage = textView.textStorage, let (shown, range) = shown(in: storage, at: index),
              storage.attribute(.attachment, at: index, effectiveRange: nil) != nil
        else { return false }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: sourceForm(of: shown, accent: textView.linkTextAttributes?[.foregroundColor] as? NSColor))
        storage.endEditing()
        return true
    }

    /// A click on the "Show diagram" line. True when `link` was that line's,
    /// whether or not there was still a diagram under it to bring back.
    static func handleLink(_ link: Any, in textView: NSTextView, at index: Int) -> Bool {
        guard ChatLinkContext.linkTargetString(from: link) == showLink else { return false }
        guard let storage = textView.textStorage, let (shown, range) = shown(in: storage, at: index) else { return true }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: pictureForm(of: shown))
        storage.endEditing()
        return true
    }

    // MARK: - The two forms

    private static func shown(in storage: NSTextStorage, at index: Int) -> (MermaidDiagramShown, NSRange)? {
        guard index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard let shown = storage.attribute(.markdownDiagramShown, at: index, longestEffectiveRange: &range,
                                            in: NSRange(location: 0, length: storage.length)) as? MermaidDiagramShown
        else { return nil }
        return (shown, range)
    }

    private static func showPicture(_ image: NSImage, in storage: NSTextStorage, replacing range: NSRange) {
        // The block as code, without the attributes that would have this
        // loader draw it again when it is put back.
        let code = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let whole = NSRange(location: 0, length: code.length)
        code.removeAttribute(.markdownDiagram, range: whole)
        code.removeAttribute(.markdownDiagramToken, range: whole)
        let shown = MermaidDiagramShown(image: image, code: NSAttributedString(attributedString: code))
        storage.replaceCharacters(in: range, with: pictureForm(of: shown))
    }

    /// The block's own line ending, when it has one: the last block of a
    /// reply has had its trailing newline trimmed, and adding one back would
    /// put an empty line under it.
    private static func ending(of shown: MermaidDiagramShown) -> String {
        shown.code.string.hasSuffix("\n") ? "\n" : ""
    }

    private static func pictureForm(of shown: MermaidDiagramShown) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownImageAttachmentCell(
            image: shown.image, logicalSize: shown.image.size, maxSize: maxSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 6
        paragraph.paragraphSpacing = 9
        var attributes: [NSAttributedString.Key: Any] = [
            .attachment: attachment,
            .paragraphStyle: paragraph,
            .markdownDiagramShown: shown,
            .cursor: NSCursor.pointingHand,
            .toolTip: "Click to show the diagram's source",
        ]
        if shown.code.length > 0, let font = shown.code.attribute(.font, at: 0, effectiveRange: nil) {
            attributes[.font] = font
        }
        return NSAttributedString(string: "\u{FFFC}" + ending(of: shown), attributes: attributes)
    }

    private static func sourceForm(of shown: MermaidDiagramShown, accent: NSColor?) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: shown.code)
        let last = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil) : [:]
        if ending(of: shown).isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: last))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        var link: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
            .link: showLink,
        ]
        if let accent { link[.foregroundColor] = accent }
        result.append(NSAttributedString(string: "Show diagram" + ending(of: shown), attributes: link))
        result.addAttribute(.markdownDiagramShown, value: shown, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func find(_ token: NSString, in storage: NSTextStorage) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(.markdownDiagramToken, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let candidate = value as? NSString, candidate == token {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Light text means a dark page. Read off the run rather than passed in,
    /// so every view that hydrates agrees with what it actually drew.
    private static func isLight(_ colour: NSColor?) -> Bool {
        guard let c = colour?.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.5
    }

    // MARK: - Loading

    private static func load(key: String, source: String, dark: Bool, scale: Int, cli: AttacheCliLink,
                             completion: @escaping (NSImage?) -> Void) {
        if let entry = images.object(forKey: key as NSString) { return completion(entry.image) }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]

        func finish(_ image: NSImage?) {
            if let image { images.setObject(Entry(image: image), forKey: key as NSString) }
            for waiter in waiting.removeValue(forKey: key) ?? [] { waiter(image) }
        }

        let url = file(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = (try? Data(contentsOf: url)).flatMap { image(from: $0, scale: scale) }
            DispatchQueue.main.async {
                if let kept { return finish(kept) }
                if let last = unanswered[key], Date().timeIntervalSince(last) < retryAfter { return finish(nil) }
                guard let argv = MermaidCommand.argv(source: source, dark: dark, scale: scale) else {
                    refused.insert(key)
                    return finish(nil)
                }
                ask {
                    cli.run(argv) { lines in
                        asked()
                        switch MermaidCommand.answer(lines) {
                        case let .picture(png, width, height):
                            unanswered[key] = nil
                            guard let image = NSImage(data: png), image.isValid else {
                                // A PNG this machine cannot decode is as
                                // final as a source attache-cli cannot draw.
                                refused.insert(key)
                                return finish(nil)
                            }
                            image.size = NSSize(width: width, height: height)
                            keep(png, at: url)
                            finish(image)
                        case .refused:
                            refused.insert(key)
                            finish(nil)
                        case .unanswered:
                            unanswered[key] = Date()
                            finish(nil)
                        }
                    }
                }
            }
        }
    }

    /// A PNG kept on disk, at the size in points it was drawn for: its
    /// pixels over the scale in its key. Nil for bytes that are not a
    /// picture — a file cut short is asked for again rather than shown.
    nonisolated private static func image(from data: Data, scale: Int) -> NSImage? {
        guard MermaidCommand.isPNG(data), let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0
        else { return nil }
        let size = NSSize(width: CGFloat(bitmap.pixelsWide) / CGFloat(scale),
                          height: CGFloat(bitmap.pixelsHigh) / CGFloat(scale))
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func ask(_ work: @escaping () -> Void) {
        if asking < maxAsking {
            asking += 1
            work()
        } else {
            queued.append(work)
        }
    }

    /// One finished: its place goes to the next in line, or is given back.
    private static func asked() {
        if queued.isEmpty {
            asking -= 1
        } else {
            queued.removeFirst()()
        }
    }

    // MARK: - Disk

    nonisolated private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "me.xueshi.attache", isDirectory: true)
            .appendingPathComponent("mermaid", isDirectory: true)
    }()

    nonisolated private static func file(_ key: String) -> URL {
        folder.appendingPathComponent(key + ".png")
    }

    private static func keep(_ png: Data, at url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: a file cut short by a quit would otherwise be read
            // back next launch as a picture that cannot be drawn.
            try? png.write(to: url, options: .atomic)
        }
    }
}
