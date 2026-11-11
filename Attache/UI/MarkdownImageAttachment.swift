//
//  MarkdownImageAttachment.swift
//  Attache
//

import AppKit
import ImageIO

/// Context passed down from `ChatPaneView` to rendered markdown views so
/// relative paths resolve against the agent pane's working directory and SSH
/// sessions never touch the local disk.
nonisolated struct ChatLinkContext {
    var cwd: String?
    var pathsAreLocal: Bool = true
    var onOpenLink: (@MainActor (String) -> Void)?
    var onLayoutInvalidated: (@MainActor () -> Void)?

    static let localDefault = ChatLinkContext()

    @MainActor
    func open(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let onOpenLink {
            onOpenLink(trimmed)
            return
        }
        Self.openFallback(trimmed, cwd: cwd, pathsAreLocal: pathsAreLocal)
    }

    static func linkTargetString(from link: Any) -> String? {
        if let string = link as? String { return string }
        if let string = link as? NSString { return string as String }
        if let url = link as? URL { return url.isFileURL ? url.absoluteString : url.absoluteString }
        return nil
    }

    @MainActor
    private static func openFallback(_ raw: String, cwd: String?, pathsAreLocal: Bool) {
        guard pathsAreLocal else {
            let target = TerminalLinkTarget.resolve(raw, cwd: nil, existence: { _ in .absent })
            if case let .url(url) = target { NSWorkspace.shared.open(url) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = TerminalLinkTarget.resolve(raw, cwd: cwd, existence: fileExistence)
            DispatchQueue.main.async {
                switch target {
                case let .url(url):
                    NSWorkspace.shared.open(url)
                case let .file(path), let .directory(path):
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                case .missing, .unsupported:
                    break
                }
            }
        }
    }

    nonisolated static func fileExistence(_ path: String) -> TerminalLinkTarget.Existence {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        return isDirectory.boolValue ? .directory : .file
    }
}

/// TextKit 1 attachment cell that clamps oversized/Retina images to a display
/// budget, scales down proportionally as its column narrows, and draws with
/// `respectFlipped: true` so flipped `NSTextView`s never invert the bitmap.
nonisolated final class MarkdownImageAttachmentCell: NSTextAttachmentCell {
    static let bodyMaxSize = NSSize(width: 520, height: 360)
    static let tableMaxSize = NSSize(width: 220, height: 180)

    let renderedImage: NSImage
    let cappedSize: NSSize
    private let verticalPad: CGFloat = 4

    @MainActor
    init(image: NSImage, logicalSize: NSSize, maxSize: NSSize) {
        renderedImage = image
        let w = max(1, logicalSize.width)
        let h = max(1, logicalSize.height)
        let scale = min(1.0, maxSize.width / w, maxSize.height / h)
        cappedSize = NSSize(
            width: max(1, round(w * scale)),
            height: max(1, round(h * scale))
        )
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    override func cellSize() -> NSSize {
        NSSize(width: ceil(cappedSize.width), height: ceil(cappedSize.height) + verticalPad * 2)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let available = max(24, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        let scale = min(1.0, available / max(1, cappedSize.width))
        let width = max(1, floor(cappedSize.width * scale))
        let height = max(1, floor(cappedSize.height * scale))
        return NSRect(x: 0, y: 0, width: width, height: height + verticalPad * 2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let imageRect = NSRect(
            x: cellFrame.minX,
            y: cellFrame.minY + verticalPad,
            width: cellFrame.width,
            height: max(1, cellFrame.height - verticalPad * 2)
        )
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)
        clip.addClip()
        renderedImage.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        let strokeRect = imageRect.insetBy(dx: 0.5, dy: 0.5)
        if strokeRect.width > 1, strokeRect.height > 1 {
            let border = NSBezierPath(roundedRect: strokeRect, xRadius: 6, yRadius: 6)
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            border.lineWidth = 1
            border.stroke()
        }
    }
}

/// Shared non-blocking image loader and `NSTextStorage` hydrator for
/// `![alt](destination)` runs.
@MainActor
enum MarkdownImageLoader {
    private final class Entry: NSObject {
        let image: NSImage
        let logicalSize: NSSize
        init(image: NSImage, logicalSize: NSSize) {
            self.image = image
            self.logicalSize = logicalSize
        }
    }

    private nonisolated struct DecodedPayload: Sendable {
        let cgImage: CGImage?
        let fallbackData: Data?
        let logicalSize: NSSize
    }

    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 96
        return c
    }()

    private static var inFlight: [String: [(Entry?) -> Void]] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private static let maxDownloadBytes = 25 * 1024 * 1024

    /// Replace `.markdownImage` runs in `storage` with `MarkdownImageAttachmentCell`s
    /// immediately on cache hits, and asynchronously off the main thread on misses.
    static func hydrate(
        _ storage: NSTextStorage,
        context: ChatLinkContext,
        maxSize: NSSize,
        onAsyncUpdate: @escaping @MainActor () -> Void
    ) {
        guard storage.length > 0 else { return }
        var runs: [(spec: MarkdownImageSpec, range: NSRange)] = []
        storage.enumerateAttribute(
            .markdownImage, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if let spec = value as? MarkdownImageSpec {
                runs.append((spec, range))
            }
        }
        guard !runs.isEmpty else { return }

        storage.beginEditing()
        var pending: [(token: NSString, spec: MarkdownImageSpec)] = []
        for (spec, range) in runs.reversed() {
            let clickLink = (storage.attribute(.link, at: range.location, effectiveRange: nil) as? NSString)
                ?? (spec.destination as NSString)
            if let key = cacheKey(for: spec.destination, context: context),
               let entry = cache.object(forKey: key as NSString)
            {
                replaceWithAttachment(
                    in: storage, range: range, entry: entry,
                    clickLink: clickLink, maxSize: maxSize
                )
            } else {
                let token = UUID().uuidString as NSString
                storage.addAttribute(.markdownImageToken, value: token, range: range)
                storage.addAttribute(.markdownImageLink, value: clickLink, range: range)
                pending.append((token, spec))
            }
        }
        storage.endEditing()

        for item in pending {
            load(destination: item.spec.destination, context: context) { [weak storage] entry in
                guard let storage, let entry else { return }
                guard let range = findToken(item.token, in: storage) else { return }
                let clickLink = (storage.attribute(.markdownImageLink, at: range.location, effectiveRange: nil) as? NSString)
                    ?? (storage.attribute(.link, at: range.location, effectiveRange: nil) as? NSString)
                    ?? (item.spec.destination as NSString)
                storage.beginEditing()
                replaceWithAttachment(
                    in: storage, range: range, entry: entry,
                    clickLink: clickLink, maxSize: maxSize
                )
                storage.endEditing()
                onAsyncUpdate()
            }
        }
    }

    static func handleAttachmentClick(
        in textView: NSTextView, at charIndex: Int, context: ChatLinkContext
    ) -> Bool {
        guard let storage = textView.textStorage,
              charIndex >= 0, charIndex < storage.length
        else { return false }
        if let dest = storage.attribute(.markdownImageLink, at: charIndex, effectiveRange: nil) as? String {
            context.open(dest)
            return true
        }
        if let link = storage.attribute(.link, at: charIndex, effectiveRange: nil),
           let dest = ChatLinkContext.linkTargetString(from: link)
        {
            context.open(dest)
            return true
        }
        return false
    }

    private static func findToken(_ token: NSString, in storage: NSTextStorage) -> NSRange? {
        guard storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(
            .markdownImageToken, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if let candidate = value as? NSString, candidate == token {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private static func replaceWithAttachment(
        in storage: NSTextStorage,
        range: NSRange,
        entry: Entry,
        clickLink: NSString,
        maxSize: NSSize
    ) {
        var existing = storage.attributes(at: range.location, effectiveRange: nil)
        existing.removeValue(forKey: .markdownImage)
        existing.removeValue(forKey: .markdownImageToken)
        existing.removeValue(forKey: .link)
        existing.removeValue(forKey: .underlineStyle)
        existing.removeValue(forKey: .foregroundColor)

        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownImageAttachmentCell(
            image: entry.image, logicalSize: entry.logicalSize, maxSize: maxSize
        )
        existing[.attachment] = attachment
        existing[.link] = clickLink
        existing[.markdownImageLink] = clickLink
        existing[.cursor] = NSCursor.pointingHand
        storage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: "\u{FFFC}", attributes: existing)
        )
    }

    // MARK: - Resolving & Loading

    private enum Source {
        case dataURI(String)
        case remoteHTTP(URL, hint: String)
        case localCandidate(raw: String, cwd: String?)
    }

    private static func classifySource(_ raw: String, context: ChatLinkContext) -> Source? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:image/") {
            return .dataURI(trimmed)
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { return nil }
            return .remoteHTTP(url, hint: url.lastPathComponent)
        }
        // Requirement zero (issue #5): never probe or read local disk when the
        // session lives on a remote SSH host.
        guard context.pathsAreLocal else { return nil }
        return .localCandidate(raw: trimmed, cwd: context.cwd)
    }

    private static func cacheKey(for raw: String, context: ChatLinkContext) -> String? {
        guard let source = classifySource(raw, context: context) else { return nil }
        switch source {
        case let .dataURI(uri):
            return "data:\(uri.hashValue):\(uri.count)"
        case let .remoteHTTP(url, _):
            return "http:\(url.absoluteString)"
        case let .localCandidate(candidate, cwd):
            return "local:\(cwd ?? ""):\(candidate)"
        }
    }

    private static func load(
        destination: String,
        context: ChatLinkContext,
        completion: @escaping @MainActor (Entry?) -> Void
    ) {
        guard let source = classifySource(destination, context: context),
              let key = cacheKey(for: destination, context: context)
        else {
            completion(nil)
            return
        }
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]

        func finish(_ payload: DecodedPayload?) {
            let entry: Entry? = payload.flatMap { makeEntry(from: $0) }
            if let entry { cache.setObject(entry, forKey: key as NSString) }
            let waiters = inFlight.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter(entry) }
        }

        switch source {
        case let .dataURI(uri):
            let limit = maxDownloadBytes
            DispatchQueue.global(qos: .utility).async {
                let decoded = decodeDataURI(uri, maxBytes: limit)
                DispatchQueue.main.async { finish(decoded) }
            }

        case let .remoteHTTP(url, hint):
            let limit = maxDownloadBytes
            let task = session.dataTask(with: url) { data, response, error in
                guard error == nil,
                      let data, !data.isEmpty, data.count <= limit
                else {
                    DispatchQueue.main.async { finish(nil) }
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    DispatchQueue.main.async { finish(nil) }
                    return
                }
                let decoded = decodeImageData(data, sourceHint: hint)
                DispatchQueue.main.async { finish(decoded) }
            }
            task.resume()

        case let .localCandidate(raw, cwd):
            let limit = maxDownloadBytes
            DispatchQueue.global(qos: .utility).async {
                let target = TerminalLinkTarget.resolve(
                    raw, cwd: cwd, existence: ChatLinkContext.fileExistence
                )
                guard case let .file(path) = target,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
                      !data.isEmpty, data.count <= limit
                else {
                    DispatchQueue.main.async { finish(nil) }
                    return
                }
                let decoded = decodeImageData(data, sourceHint: (path as NSString).lastPathComponent)
                DispatchQueue.main.async { finish(decoded) }
            }
        }
    }

    private static func makeEntry(from payload: DecodedPayload) -> Entry? {
        if let cgImage = payload.cgImage {
            let image = NSImage(cgImage: cgImage, size: payload.logicalSize)
            return Entry(image: image, logicalSize: payload.logicalSize)
        }
        if let data = payload.fallbackData, let image = NSImage(data: data),
           image.size.width > 0, image.size.height > 0
        {
            let size = payload.logicalSize.width > 0 ? payload.logicalSize : image.size
            return Entry(image: image, logicalSize: size)
        }
        return nil
    }

    nonisolated private static func decodeDataURI(_ uri: String, maxBytes: Int) -> DecodedPayload? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[..<comma].lowercased()
        let body = String(uri[uri.index(after: comma)...])
        let data: Data?
        if header.contains(";base64") {
            data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters])
        } else {
            data = body.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty, data.count <= maxBytes else { return nil }
        return decodeImageData(data, sourceHint: header)
    }

    nonisolated private static func decodeImageData(_ data: Data, sourceHint: String) -> DecodedPayload? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(
               source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
           ),
           cgImage.width > 0, cgImage.height > 0
        {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpiW = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
            let dpiH = (props?[kCGImagePropertyDPIHeight] as? CGFloat) ?? 72
            var logicalW = CGFloat(cgImage.width) * 72.0 / (dpiW > 0 ? dpiW : 72.0)
            var logicalH = CGFloat(cgImage.height) * 72.0 / (dpiH > 0 ? dpiH : 72.0)

            let hintLower = sourceHint.lowercased()
            if hintLower.contains("@3x."), abs(CGFloat(cgImage.width) - logicalW) < 1 {
                logicalW /= 3
                logicalH /= 3
            } else if hintLower.contains("@2x."), abs(CGFloat(cgImage.width) - logicalW) < 1 {
                logicalW /= 2
                logicalH /= 2
            }
            return DecodedPayload(
                cgImage: cgImage,
                fallbackData: nil,
                logicalSize: NSSize(width: max(1, logicalW), height: max(1, logicalH))
            )
        }
        // Vector/PDF fallback handled on the main actor via `NSImage(data:)`.
        return DecodedPayload(cgImage: nil, fallbackData: data, logicalSize: .zero)
    }
}
