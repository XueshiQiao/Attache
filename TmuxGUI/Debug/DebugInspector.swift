//
//  DebugInspector.swift
//  TmuxGUI
//

#if DEBUG

    import Cocoa

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
                return TmuxReport(tmuxPath: nil, shownSession: nil, sessions: [])
            }
            return TmuxReport(
                tmuxPath: main.server.tmuxPath,
                shownSession: main.debugShownSessionName,
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
        }

        // MARK: tmux side

        struct TmuxReport: Encodable {
            let tmuxPath: String?
            /// Which session the content area is showing right now.
            let shownSession: String?
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
