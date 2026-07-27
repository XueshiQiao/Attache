//
//  DebugInspector.swift
//  TmuxGUI
//

#if DEBUG

    import Cocoa
    import GhosttyTheme

    /// A machine-readable dump of what the app currently believes.
    ///
    /// Two questions cost hours in this project and neither one is answerable
    /// from a screenshot:
    ///
    /// 1. *Why does a view with a correct frame render nothing?* On macOS 26 a
    ///    view that draws gets a backing layer taller than itself, and the
    ///    overhang paints over whichever sibling was added first. The view's own
    ///    frame, `isHidden` and `alphaValue` all look right; only the layer's
    ///    size gives it away. `ViewNode.layer.overhang` is that number.
    ///
    /// 2. *Does the app agree with tmux?* The app is supposed to hold no
    ///    authored state, so every window, layout and pane id it reports should
    ///    be identical to `tmux list-windows`. `TmuxReport` prints them in a
    ///    shape that diffs against tmux's own output directly.
    ///
    /// Debug builds only, and the whole file compiles away in Release.
    @MainActor
    enum DebugInspector {
        /// Set once by `AppDelegate`. Weak, so the inspector can never be the
        /// reason a controller stays alive.
        static weak var main: MainViewController?

        /// Where `writeSnapshot()` puts its file. Fixed rather than under
        /// `$TMPDIR`, which macOS randomises per app — an agent has to be able
        /// to name the path without asking the app where it went.
        static let snapshotURL = URL(fileURLWithPath: "/tmp/tmuxgui/inspect.json")

        // MARK: - Reports

        static func report() -> Report {
            Report(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                windows: NSApp.windows.map(WindowNode.init(window:)),
                tmux: tmuxReport()
            )
        }

        static func viewsOnly() -> ViewsReport {
            ViewsReport(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                windows: NSApp.windows.map(WindowNode.init(window:))
            )
        }

        static func tmuxOnly() -> TmuxOnlyReport {
            TmuxOnlyReport(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                tmux: tmuxReport()
            )
        }

        private static func tmuxReport() -> TmuxReport {
            guard let main else {
                return TmuxReport(
                    tmuxPath: nil, shownSession: nil, sessionControllers: [], sessions: []
                )
            }
            return TmuxReport(
                tmuxPath: main.server.tmuxPath,
                shownSession: main.debugShownSessionName,
                sessionControllers: main.debugSessionControllerNames,
                sessions: main.debugSessionReports()
            )
        }

        // MARK: - Encoding

        /// Sorted keys and pretty printing, because the point of the dump is to
        /// be diffed — against a previous run, or against tmux.
        static func encode(_ value: some Encodable) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        }

        /// Body for one inspector path. Shared by the menu item and the HTTP
        /// endpoint so the two can never drift.
        static func body(forPath path: String) -> Data? {
            switch path {
            case "/", "/snapshot": encode(report())
            case "/views": encode(viewsOnly())
            case "/tmux": encode(tmuxOnly())
            default: nil
            }
        }

        // MARK: - Settings

        /// Read, and optionally change, the settings — over the same endpoint
        /// the rest of the dump is served from.
        ///
        /// This exists because the two settings that carry real risk, font
        /// family and size, change the size of a character cell, and the only
        /// honest way to check that the app and tmux still agree on the column
        /// count afterwards is to make the change *while the app is running*
        /// and re-read both sides. Every other route to that change needs a
        /// pointer on the screen.
        ///
        /// Read-write, unlike the rest of the inspector, and therefore Debug
        /// only along with the rest of this file. Deliberately does not expose
        /// whether closing a tab kills its window: that one ends processes, and
        /// nothing destructive should have an unattended path to it.
        static func settingsBody(query: String) -> Data {
            let parameters = parseQuery(query)
            var changed = [String]()

            if let raw = parameters["fontSize"], let value = Double(raw) {
                AppSettings.fontSize = value
                changed.append("fontSize")
            }
            if let value = parameters["fontFamily"] {
                AppSettings.fontFamily = value
                changed.append("fontFamily")
            }
            if let raw = parameters["appearance"], let value = AppSettings.Appearance(rawValue: raw) {
                AppSettings.appearance = value
                AppSettings.applyAppearanceOverride()
                changed.append("appearance")
            }
            if let value = parameters["lightTheme"] {
                AppSettings.lightThemeName = value
                changed.append("lightTheme")
            }
            if let value = parameters["darkTheme"] {
                AppSettings.darkThemeName = value
                changed.append("darkTheme")
            }
            if let raw = parameters["sidebarWidth"], let value = Double(raw) {
                AppSettings.sidebarWidth = CGFloat(value)
                changed.append("sidebarWidth")
            }
            if let raw = parameters["scrollbackPrimeLines"], let value = Int(raw) {
                AppSettings.scrollbackPrimeLines = value
                changed.append("scrollbackPrimeLines")
            }

            if !changed.isEmpty {
                TmuxLog.lifecycle("inspector changed settings: \(changed.joined(separator: ", "))")
                AppSettings.notifyChanged()
            }

            return encode(SettingsReport(changed: changed.sorted()))
        }

        /// Resize or move the app's window. Exists so the "does stale state
        /// survive a resize" question — which is where grid bugs usually
        /// surface, on the pass *after* the one that broke — can be asked
        /// without a pointer.
        ///
        /// `position` matters as much as `size`, because looking at the result
        /// means `screencapture`, and that fails outright on a window sitting
        /// on a secondary display: both `-R` with a negative x and `-l` on a
        /// window belonging to another display's Space answer "could not create
        /// image". `?position=0,0&screen=main` parks the window somewhere a
        /// capture can reach it.
        static func resizeWindowBody(query: String) -> Data {
            let parameters = parseQuery(query)
            let window = NSApp.windows.first { $0.contentViewController === main }

            if let raw = parameters["size"], let window {
                let parts = raw.lowercased().split(separator: "x")
                if parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) {
                    window.setContentSize(NSSize(width: width, height: height))
                }
            }
            // Both ordered after the resize: they place a corner, and a resize
            // afterwards would move the corner that was just placed.
            if parameters["screen"] == "primary", let window,
               let primary = NSScreen.screens.first
            {
                let frame = window.frame
                window.setFrameOrigin(NSPoint(
                    x: primary.visibleFrame.midX - frame.width / 2,
                    y: primary.visibleFrame.midY - frame.height / 2
                ))
            }
            // Screen coordinates as `screencapture` counts them: from the
            // top-left of the primary display, y downwards. Asking an agent to
            // flip the axis itself is how a capture ends up off by the height
            // of the window.
            if let raw = parameters["position"], let window,
               let primary = NSScreen.screens.first
            {
                let parts = raw.split(separator: ",")
                if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                    window.setFrameTopLeftPoint(NSPoint(x: x, y: primary.frame.maxY - y))
                }
            }
            return encode(WindowSizeReport())
        }

        /// Write a PNG of the app's own window.
        ///
        /// `screencapture` is the obvious tool and is not always available: it
        /// needs Screen Recording consent, which belongs to whatever terminal
        /// an agent happens to be running under, and without it every form of
        /// the command — `-R` on a region, `-l` on a window id — fails with
        /// "could not create image". An agent cannot grant itself that consent,
        /// so a project whose whole verification story is "take a screenshot
        /// and look at it" needs a route that does not depend on it.
        ///
        /// An app photographing its own window needs no permission, and this
        /// captures nothing else on the display — strictly less than
        /// `screencapture` would.
        ///
        /// Two methods, because they see different things:
        ///
        /// - `window` composites the real window, terminal content included.
        /// - `view` re-renders the AppKit view tree, which is enough for chrome
        ///   and misses anything drawn by Metal — every pane comes out empty.
        ///   Useful precisely for that: it separates "the chrome is wrong" from
        ///   "the terminal drew nothing".
        static func screenshotBody(query: String) -> Data {
            let parameters = parseQuery(query)
            let path = parameters["path"] ?? "/tmp/tmuxgui/shot.png"
            let method = parameters["method"] ?? "window"

            // Temporary directories and `.png` only. Writing the file is the
            // one thing on this endpoint that destroys something, and without a
            // restriction a plain `GET` names any path the user can write —
            // `?path=…/README.md` overwrites it with a screenshot, atomically
            // and without a word. Scratch directories are where a caller wants
            // the file anyway.
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            guard resolved.hasSuffix(".png"),
                  resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/")
                  || resolved.hasPrefix("/private/var/folders/")
            else {
                return encode(ScreenshotReport(
                    path: path, method: method,
                    error: "path must be a .png under /tmp or the system temporary directory"
                ))
            }

            guard let window = NSApp.windows.first(where: { $0.contentViewController === main })
            else { return encode(ScreenshotReport(path: path, method: method, error: "no window")) }

            // `subview=SomeViewClass` renders one view and its own subtree.
            // The reason it exists: a `view` capture of the whole window
            // re-renders every sibling, and a system material sibling has no
            // desktop to sample in a cached render, so it comes out opaque
            // white over whatever it overlaps. Rendering the component alone
            // answers "is this view drawing what it should" without the
            // material in the way.
            let target = parameters["subview"].flatMap { name in
                window.contentView.flatMap { Self.firstView(in: $0, named: name) }
            } ?? (method == "view" ? window.contentView : nil)

            let image: CGImage?
            if let target, let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
                target.cacheDisplay(in: target.bounds, to: rep)
                image = rep.cgImage
            } else {
                // Deprecated since macOS 14 in favour of ScreenCaptureKit,
                // which is asynchronous and — the point of this route — gated
                // on the very consent that is missing. Still the only
                // synchronous way to composite one's own window.
                image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    CGWindowID(window.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]
                )
            }

            guard let image else {
                return encode(ScreenshotReport(path: path, method: method, error: "capture failed"))
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                return encode(ScreenshotReport(path: path, method: method, error: "png encoding failed"))
            }
            do {
                // `resolved`, not `path`: the write has to land on the path the
                // guard above vetted, or the guard is decoration.
                let url = URL(fileURLWithPath: resolved)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                return encode(ScreenshotReport(
                    path: path, method: method, error: String(describing: error)
                ))
            }
            return encode(ScreenshotReport(
                path: path, method: method,
                pixelSize: Size(CGSize(width: image.width, height: image.height))
            ))
        }

        /// `?session=name` — show a session, the way clicking its row would.
        ///
        /// The app opens on whichever session tmux lists first and every other
        /// one is a click away, so without this the only session an unattended
        /// run can look at is the alphabetically first — which is rarely the
        /// one with the interesting layout in it. Non-destructive: it selects,
        /// exactly like the rail does.
        static func selectBody(query: String) -> Data {
            if let name = parseQuery(query)["session"] { main?.show(sessionNamed: name) }
            return encode(tmuxOnly())
        }

        /// `?cellPixels=24x50` — hand a grid a cell size, the way a surface
        /// would after a font change. See
        /// `SessionViewController.debugAdoptCellSize`.
        ///
        /// `&session=name` aims it at a session that is *not* on screen, which
        /// is the case worth being able to reach: a font change reaches every
        /// session controller, and an off-screen one's view has no window, no
        /// current bounds and no honest grid to report.
        static func gridBody(query: String) -> Data {
            let parameters = parseQuery(query)
            let target = parameters["session"].flatMap { main?.debugSessionController(named: $0) }
                ?? main?.currentSession
            if let raw = parameters["cellPixels"] {
                let parts = raw.lowercased().split(separator: "x")
                if parts.count == 2, let width = UInt32(parts[0]), let height = UInt32(parts[1]),
                   // Bounded, and not as tidiness. The cell size divides the
                   // view to produce the grid this app *sends to tmux*: an
                   // absurd cell floors that division to zero, `gridSize`
                   // clamps it to one, and the session on screen is told
                   // `refresh-client -C 1x1` — every window in it reflowed to a
                   // single cell, with whatever was running inside. A debug
                   // route that can do that unattended has no business
                   // existing. The range spans every plausible font size at
                   // every plausible scale factor.
                   (2 ... 400).contains(width), (2 ... 400).contains(height)
                {
                    target?.debugAdoptCellSize(widthPixels: width, heightPixels: height)
                }
            }
            return encode(tmuxOnly())
        }

        private static func firstView(in root: NSView, named name: String) -> NSView? {
            if String(describing: type(of: root)) == name { return root }
            for subview in root.subviews {
                if let found = firstView(in: subview, named: name) { return found }
            }
            return nil
        }

        /// Build the settings window off screen and report what came out.
        ///
        /// Showing it would take the user's focus, so this only forces the
        /// SwiftUI tree to be constructed and laid out. That is enough to catch
        /// the failures that are silent until the window is opened — a picker
        /// whose selection matches no tag, a `ForEach` over colliding ids — and
        /// nothing at all about whether it looks right, which still needs eyes.
        static func settingsWindowBody(query: String) -> Data {
            let requested = parseQuery(query)["page"] ?? ""
            let page = SettingsPage.allCases.first { $0.axID == requested } ?? .terminal
            let controller = SettingsWindowController { $0("not run from the inspector") }
            let root = controller.debugBuildOffScreen(page: page)
            root.layoutSubtreeIfNeeded()
            return encode(ViewsReport(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                windows: [WindowNode(offScreenRoot: root)]
            ))
        }

        /// `a=b&c=d`, percent-decoded, with `+` read as a space so a font
        /// family can be passed the way a browser would send it.
        private static func parseQuery(_ query: String) -> [String: String] {
            var parameters = [String: String]()
            for pair in query.split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard let name = halves.first else { continue }
                let raw = halves.count > 1 ? String(halves[1]) : ""
                let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
                parameters[String(name)] = decoded
            }
            return parameters
        }

        @discardableResult
        static func writeSnapshot() -> Result<URL, Error> {
            do {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try encode(report()).write(to: snapshotURL, options: .atomic)
                return .success(snapshotURL)
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: - Shapes

    extension DebugInspector {
        struct Report: Encodable {
            let generatedAt: String
            let windows: [WindowNode]
            let tmux: TmuxReport
        }

        struct ViewsReport: Encodable {
            let generatedAt: String
            let windows: [WindowNode]
        }

        struct TmuxOnlyReport: Encodable {
            let generatedAt: String
            let tmux: TmuxReport
        }

        /// What the settings endpoint answers with: which keys the request
        /// changed, and every value as it reads back afterwards — clamped, so
        /// an out-of-range request shows what the app actually took.
        struct SettingsReport: Encodable {
            let changed: [String]
            let fontFamily: String
            let fontSize: Double
            let appearance: String
            let lightTheme: String
            let darkTheme: String
            let effectiveTheme: String
            let isShowingDarkAppearance: Bool
            let scrollbackPrimeLines: Int
            let sidebarWidth: Double
            let closingTabKillsWindow: Bool
            /// The derived chrome, as hex. Every one of these is a blend of the
            /// scheme's own foreground and background except `accent`, which is
            /// picked from the scheme's highlight colours and has to clear a
            /// contrast floor — so this is where a scheme that would have made
            /// the selection invisible shows up as a different value.
            let chrome: [String: String]
            let accentContrast: Double
            let accentSource: String

            @MainActor
            init(changed: [String]) {
                self.changed = changed
                fontFamily = AppSettings.fontFamily
                fontSize = AppSettings.fontSize
                appearance = AppSettings.appearance.rawValue
                lightTheme = AppSettings.lightThemeName
                darkTheme = AppSettings.darkThemeName
                effectiveTheme = AppSettings.effectiveThemeDefinition().name
                isShowingDarkAppearance = AppSettings.isShowingDarkAppearance
                scrollbackPrimeLines = AppSettings.scrollbackPrimeLines
                sidebarWidth = Double(AppSettings.sidebarWidth)
                closingTabKillsWindow = AppSettings.closingTabKillsWindow

                let theme = ChromeTheme.current
                chrome = [
                    "background": Self.hex(theme.background),
                    "text": Self.hex(theme.text),
                    "mutedText": Self.hex(theme.mutedText),
                    "faintText": Self.hex(theme.faintText),
                    "separator": Self.hex(theme.separator),
                    "hover": Self.hex(theme.hover),
                    "accent": Self.hex(theme.accent),
                    "onAccent": Self.hex(theme.onAccent),
                    "windowBackground": NSApp.windows
                        .first(where: { $0.contentViewController === DebugInspector.main })?
                        .backgroundColor.map(Self.hex) ?? "?",
                ]
                accentContrast = (Double(
                    ChromeTheme.contrastRatio(theme.accent, theme.background)
                ) * 100).rounded() / 100
                let definition = AppSettings.effectiveThemeDefinition()
                accentSource = [
                    ("cursorColor", definition.cursorColor),
                    ("palette4", definition.palette[4]),
                    ("palette12", definition.palette[12]),
                    ("selectionBackground", definition.selectionBackground),
                ]
                .first { _, hex in
                    hex.flatMap(ChromeTheme.color(hex:)).map { Self.hex($0) } == Self.hex(theme.accent)
                }?.0 ?? "foreground (nothing cleared the contrast floor)"
            }

            private static func hex(_ color: NSColor) -> String {
                guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
                return String(
                    format: "#%02X%02X%02X",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded())
                )
            }
        }

        /// Where the PNG went, or why it did not.
        struct ScreenshotReport: Encodable {
            let path: String
            let method: String
            let pixelSize: Size?
            let error: String?

            init(path: String, method: String, pixelSize: Size? = nil, error: String? = nil) {
                self.path = path
                self.method = method
                self.pixelSize = pixelSize
                self.error = error
            }
        }

        /// The window's content size, so a resize can be confirmed rather than
        /// assumed, plus everything needed to point `screencapture` at it.
        struct WindowSizeReport: Encodable {
            let contentSize: Size
            /// AppKit's own frame: global, origin at the primary display's
            /// bottom-left, y upwards.
            let windowFrame: Rect
            /// The same rect in `screencapture`'s space — y downwards from the
            /// primary display's top-left — ready to paste after `-R`.
            let captureRegion: String
            /// Whether that region is on the primary display. `screencapture`
            /// answers "could not create image from rect" for anything else,
            /// which reads as a broken command rather than a misplaced window.
            let isOnPrimaryScreen: Bool

            @MainActor
            init() {
                let window = NSApp.windows.first { $0.contentViewController === DebugInspector.main }
                contentSize = Size(window?.contentView?.bounds.size ?? .zero)
                let frame = window?.frame ?? .zero
                windowFrame = Rect(frame)
                let primary = NSScreen.screens.first?.frame ?? .zero
                let top = primary.maxY - frame.maxY
                captureRegion = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
                // The whole rect, not its middle: `screencapture` fails on a
                // region that runs off the primary display at all, so a window
                // straddling the edge has to answer false.
                isOnPrimaryScreen = primary.contains(frame)
            }
        }

        struct Rect: Encodable {
            let x, y, width, height: Double

            init(_ rect: CGRect) {
                // Two decimals: enough to see a half-point misalignment,
                // stable enough that two runs of an unchanged layout produce an
                // identical file.
                x = Self.round(rect.origin.x)
                y = Self.round(rect.origin.y)
                width = Self.round(rect.size.width)
                height = Self.round(rect.size.height)
            }

            private static func round(_ value: CGFloat) -> Double {
                (Double(value) * 100).rounded() / 100
            }
        }

        struct Size: Encodable {
            let width, height: Double

            init(_ size: CGSize) {
                width = (Double(size.width) * 100).rounded() / 100
                height = (Double(size.height) * 100).rounded() / 100
            }
        }

        struct LayerInfo: Encodable {
            let frame: Rect
            let bounds: Rect
            let masksToBounds: Bool
            let opacity: Double
            let isHidden: Bool
            /// Backing layer size minus the view's own size.
            ///
            /// This is the field the dump exists for. A non-zero height here is
            /// the macOS 26 scroll-edge overhang: the layer draws outside the
            /// view's bounds, unclipped, over whatever sibling was added
            /// earlier. Nothing else in a view's state hints at it.
            let overhang: Size
        }

        struct ViewNode: Encodable {
            let type: String
            let identifier: String?
            let accessibilityLabel: String?
            let frameInWindow: Rect
            let bounds: Rect
            let isHidden: Bool
            /// True when this view or any ancestor is hidden. A view can be
            /// `isHidden == false` and still never draw.
            let isEffectivelyHidden: Bool
            let alpha: Double
            let wantsLayer: Bool
            /// `top,left,bottom,right`. The system's own answer to "how far in
            /// is it safe to draw", and the only honest input for clearing the
            /// traffic lights. Invisible in every other form of inspection.
            let safeAreaInsets: String
            let layer: LayerInfo?
            let subviews: [ViewNode]

            init(view: NSView, hiddenAncestor: Bool = false) {
                type = String(describing: Swift.type(of: view))
                identifier = view.identifier?.rawValue
                accessibilityLabel = view.accessibilityLabel()
                frameInWindow = Rect(view.convert(view.bounds, to: nil))
                bounds = Rect(view.bounds)
                isHidden = view.isHidden
                isEffectivelyHidden = hiddenAncestor || view.isHidden
                alpha = (Double(view.alphaValue) * 1000).rounded() / 1000
                wantsLayer = view.wantsLayer
                let insets = view.safeAreaInsets
                safeAreaInsets = "\(insets.top),\(insets.left),\(insets.bottom),\(insets.right)"
                layer = view.layer.map { layer in
                    LayerInfo(
                        frame: Rect(layer.frame),
                        bounds: Rect(layer.bounds),
                        masksToBounds: layer.masksToBounds,
                        opacity: (Double(layer.opacity) * 1000).rounded() / 1000,
                        isHidden: layer.isHidden,
                        overhang: Size(CGSize(
                            width: layer.bounds.width - view.bounds.width,
                            height: layer.bounds.height - view.bounds.height
                        ))
                    )
                }
                subviews = view.subviews.map {
                    ViewNode(view: $0, hiddenAncestor: hiddenAncestor || view.isHidden)
                }
            }
        }

        struct WindowNode: Encodable {
            let title: String
            let type: String
            let frame: Rect
            let isKey: Bool
            let isVisible: Bool
            let backingScaleFactor: Double
            let firstResponder: String?
            let contentView: ViewNode?

            init(window: NSWindow) {
                title = window.title
                type = String(describing: Swift.type(of: window))
                frame = Rect(window.frame)
                isKey = window.isKeyWindow
                isVisible = window.isVisible
                backingScaleFactor = Double(window.backingScaleFactor)
                firstResponder = window.firstResponder.map { responder in
                    let name = String(describing: Swift.type(of: responder))
                    if let label = (responder as? NSView)?.accessibilityLabel() {
                        return "\(name) (\(label))"
                    }
                    return name
                }
                contentView = window.contentView.map { ViewNode(view: $0) }
            }

            /// A hierarchy that was never put in a window. Used for the
            /// settings window, which is built off screen so the check cannot
            /// take the user's focus.
            init(offScreenRoot: NSView) {
                title = "TmuxGUI Settings (built off screen)"
                type = String(describing: Swift.type(of: offScreenRoot))
                frame = Rect(offScreenRoot.frame)
                isKey = false
                isVisible = false
                backingScaleFactor = Double(NSScreen.main?.backingScaleFactor ?? 1)
                firstResponder = nil
                contentView = ViewNode(view: offScreenRoot)
            }
        }

        // MARK: tmux side

        struct TmuxReport: Encodable {
            let tmuxPath: String?
            /// Which session the content area is showing right now.
            let shownSession: String?
            /// Every session the app is holding a view controller for, whether
            /// or not tmux still has that session.
            ///
            /// `sessions` below is generated from what tmux currently has, so
            /// a controller for a session that is gone does not appear in it at
            /// all — the one piece of app state a leftover could hide in was
            /// the only thing this dump could not see. A name here that is
            /// missing from `sessions` is a controller, its GPU surfaces and
            /// its panes still registered to a router nobody feeds.
            let sessionControllers: [String]
            let sessions: [SessionReport]
        }

        struct SessionReport: Encodable {
            let name: String
            /// tmux's own `$n`. Nil until `%session-changed` has arrived.
            let sessionID: String?
            let isShown: Bool
            let hasSurfaces: Bool
            let activeWindowID: String?
            let hiddenWindowIDs: [String]
            let focusedPaneID: String?
            /// The last `refresh-client -C` this app sent, i.e. what tmux was
            /// told the window is. Compare against `tmux list-windows -F
            /// '#{window_width}x#{window_height}'`.
            let reportedGrid: GridSize?
            let grid: GridViewReport?
            let windows: [WindowReport]
            let surfaces: [SurfaceReport]
        }

        struct GridSize: Encodable {
            let columns: Int
            let rows: Int
        }

        /// What `PaneGridView` is measuring in. A wrong cell size or a stale
        /// overhead is how the app and tmux end up one column apart.
        struct GridViewReport: Encodable {
            let boundsInPoints: Rect
            let pixelScale: Double
            let cellSizeInPoints: Size
            let cellSizeInPixels: Size
            /// The cell size the panes are actually placed at. Differs from
            /// `cellSizeInPoints` only while a font change is waiting for tmux
            /// to answer with a layout for the new grid.
            let layoutCellSizeInPoints: Size
            /// The window size tmux drew the current layout for. When this
            /// stops matching `computedGrid`, the two sides have stopped
            /// agreeing and every wrapped line after that breaks in the wrong
            /// place.
            let layoutGrid: GridSize?
            /// What the placed panes add up to. The number nobody had: the
            /// column counts can all agree while this runs off the view.
            let placedSizeInPoints: Size?
            let overflowsBounds: Bool
            let measuredSurfaceOverheadInPixels: Size
            /// What `gridSize` computes right now, before any coalescing.
            let computedGrid: GridSize
            let splitterCount: Int
        }

        struct WindowReport: Encodable {
            let id: String
            let index: Int
            let name: String
            let isActive: Bool
            let hasActivity: Bool
            let isHiddenFromStrip: Bool
            let layoutText: String
            let panes: [PaneReport]
            let layoutError: String?

            init(window: TmuxWindow, isHiddenFromStrip: Bool) {
                id = window.id
                index = window.index
                name = window.name
                isActive = window.isActive
                hasActivity = window.hasActivity
                self.isHiddenFromStrip = isHiddenFromStrip
                layoutText = window.layoutText
                do {
                    let node = try TmuxLayout.parse(window.layoutText)
                    panes = node.panes.map { PaneReport(id: $0.id, frame: $0.frame) }
                    layoutError = nil
                } catch {
                    panes = []
                    layoutError = String(describing: error)
                }
            }
        }

        /// One pane's geometry in tmux's character grid. Lines up field for
        /// field with `tmux list-panes -F '#{pane_id} #{pane_width}x#{pane_height} #{pane_left},#{pane_top}'`.
        struct PaneReport: Encodable {
            let id: String
            let columns: Int
            let rows: Int
            let x: Int
            let y: Int

            init(id: String, frame: TmuxLayoutFrame) {
                self.id = id
                columns = frame.columns
                rows = frame.rows
                x = frame.x
                y = frame.y
            }
        }

        /// A libghostty surface and the grid it actually resolved to. When
        /// `grid` here disagrees with the pane's `columns`/`rows` above, the two
        /// sides have drifted and every wrapped line is breaking in the wrong
        /// place.
        struct SurfaceReport: Encodable {
            let paneID: String
            let hasPrimedHistory: Bool
            let isAttached: Bool
            let viewFrame: Rect
            let grid: GridSize?
            let cellSizeInPixels: Size?
        }
    }

    extension DebugInspector.SessionReport {
        /// A session that is connected but has never been shown. It has no
        /// surfaces and no grid of its own — everything here comes from tmux,
        /// which is the half worth diffing anyway.
        init(connection: TmuxSessionConnection) {
            self.init(
                name: connection.sessionName,
                sessionID: connection.debugSessionID,
                isShown: false,
                hasSurfaces: false,
                activeWindowID: connection.activeWindowID,
                hiddenWindowIDs: [],
                focusedPaneID: nil,
                reportedGrid: connection.debugLastReportedGrid.map {
                    DebugInspector.GridSize(columns: $0.columns, rows: $0.rows)
                },
                grid: nil,
                windows: connection.windows.map {
                    DebugInspector.WindowReport(window: $0, isHiddenFromStrip: false)
                },
                surfaces: []
            )
        }
    }

#endif
