//
//  CommandExpectation.swift
//  Attache
//

import Foundation

/// The model as diagnostics is allowed to see it: plain values, copied on the
/// main queue at a known instant.
///
/// A value type on purpose. Diagnostics runs its checks against *this*, never
/// against the live model objects, so a probe can hold facts across an async
/// hop without racing the main thread — and so the whole expectation engine
/// compiles standalone for `Tools/ExpectationCheck`, the same arrangement
/// `TerminalReply` has with its check tool.
struct DiagnosticsWindowFacts {
    let id: String
    let index: Int
    let name: String
    let activePaneID: String
    let paneIDs: [String]
    let savedLayout: String
    let visibleLayout: String

    /// The same derivation `DebugInspector` and the pane menu use: the two
    /// layouts differ exactly while a pane is zoomed. There is no zoom flag to
    /// read from a `list-windows` reply.
    var isZoomed: Bool { savedLayout != visibleLayout }
}

struct DiagnosticsFacts {
    let activeWindowID: String?
    let windows: [DiagnosticsWindowFacts]

    func window(_ id: String) -> DiagnosticsWindowFacts? {
        windows.first { $0.id == id }
    }

    func windowContaining(pane: String) -> DiagnosticsWindowFacts? {
        windows.first { $0.paneIDs.contains(pane) }
    }
}

/// What a command that just went out entitles the app to observe, derived from
/// the command text alone.
///
/// Derived, never registered. `TmuxLog.command()` is the one gate every
/// command passes through, so reading the text there covers every call site
/// that exists and every one that will be added — the alternative, each UI
/// action registering its own expectation, rots on the first action nobody
/// remembers to annotate. That is the design's §3 and it is the part that must
/// not be "simplified" back.
///
/// Two deadlines per expectation, and the split is deliberate (§4): at
/// `logAfter` the anomaly is written to disk, where a false positive costs
/// nothing and a slow round trip is still worth knowing about; only at
/// `toastAfter` — never earlier than 1.5 s — is the user told, because a toast
/// that cries wolf gets ignored and an ignored mechanism is worse than none.
struct CommandExpectation {
    enum Check: Equatable {
        /// `select-window -t @9` — the active window becomes that one.
        case activeWindow(String)
        /// `select-pane -t %606` — the window holding that pane reports it
        /// active. Not "the active window's pane": a `select-pane` does not
        /// switch windows, and judging it against whichever window is current
        /// would fail it for ever when it targets a background window.
        case activePane(String)
        /// `split-window -t %584` — the window that held the pane grows.
        case paneCountRises(windowID: String, wasPanes: Int)
        /// `kill-pane -t %x` — the pane leaves every window's pane set.
        case paneGone(String)
        /// `kill-window -t @x` — the window leaves the list.
        case windowGone(String)
        /// `new-window` — the set of window ids changes.
        case windowListChanges(wasIDs: Set<String>)
        /// `resize-pane -Z -t %x` — the zoom derivation flips.
        case zoomFlips(windowID: String, wasZoomed: Bool)
        /// `resize-pane -x/-y` — either layout string of the pane's window
        /// moves. Which one moves depends on zoom state, so both are watched.
        case layoutChanges(windowID: String, wasSaved: String, wasVisible: String)
    }

    let check: Check
    /// The redacted command text, verbatim, for the anomaly line.
    let command: String
    /// Toast title. Written as what did not happen, because that is the fact
    /// the app actually knows — "Window did not switch", not "tmux is broken".
    let title: String
    /// Toast body fragment naming the target in the user's vocabulary
    /// ("window 8 · dotfiles"), resolved at derivation time while the model
    /// still names it.
    let subject: String
    let logAfter: TimeInterval
    let toastAfter: TimeInterval
    /// Collapses a click storm into one pending expectation: a re-send of the
    /// same intent replaces its predecessor rather than queueing a second
    /// toast behind it.
    var dedupeKey: String { title + "|" + subject }
    /// Snapshot filename fragment.
    let kind: String

    /// Whether `facts` satisfy this expectation. `nil` means the question
    /// cannot be answered — the target is not in the model at all — which is
    /// not success: it is held as unmet and the deadline report says so,
    /// because "the model does not even contain what I just acted on" is
    /// precisely the staleness this exists to catch.
    func isMet(_ facts: DiagnosticsFacts) -> Bool? {
        switch check {
        case .activeWindow(let id):
            return facts.activeWindowID == id
        case .activePane(let id):
            guard let window = facts.windowContaining(pane: id) else { return nil }
            return window.activePaneID == id
        case .paneCountRises(let windowID, let was):
            guard let window = facts.window(windowID) else { return nil }
            return window.paneIDs.count > was
        case .paneGone(let id):
            return facts.windowContaining(pane: id) == nil
        case .windowGone(let id):
            return facts.window(id) == nil
        case .windowListChanges(let was):
            return Set(facts.windows.map(\.id)) != was
        case .zoomFlips(let windowID, let was):
            guard let window = facts.window(windowID) else { return nil }
            return window.isZoomed != was
        case .layoutChanges(let windowID, let saved, let visible):
            guard let window = facts.window(windowID) else { return nil }
            return window.savedLayout != saved || window.visibleLayout != visible
        }
    }

    /// One parenthesised clause for the anomaly line: what the model still
    /// says instead. Written against the same facts that failed the check, so
    /// the line carries the disagreement and not just its existence.
    func unmetDetail(_ facts: DiagnosticsFacts) -> String {
        switch check {
        case .activeWindow:
            return "(active window still \(facts.activeWindowID ?? "unknown"))"
        case .activePane(let id):
            guard let window = facts.windowContaining(pane: id) else {
                return "(pane \(id) not in the window list)"
            }
            return "(window \(window.id) active pane still \(window.activePaneID))"
        case .paneCountRises(let windowID, let was):
            guard let window = facts.window(windowID) else {
                return "(window \(windowID) not in the window list)"
            }
            return "(window \(windowID) still has \(window.paneIDs.count) pane(s), had \(was))"
        case .paneGone(let id):
            return "(pane \(id) still present)"
        case .windowGone(let id):
            return "(window \(id) still present)"
        case .windowListChanges(let was):
            return "(window list still the same \(was.count) id(s))"
        case .zoomFlips(let windowID, let was):
            guard let window = facts.window(windowID) else {
                return "(window \(windowID) not in the window list)"
            }
            return "(window \(windowID) still \(window.isZoomed ? "zoomed" : "unzoomed"), was \(was ? "zoomed" : "unzoomed"))"
        case .layoutChanges(let windowID, _, _):
            return "(window \(windowID) layout unchanged)"
        }
    }

    // MARK: - Derivation

    /// Deadlines from the design's table. 300 ms for state tmux flips
    /// immediately and announces immediately; 1500 ms for structural changes
    /// that go through a `%layout-change`/`list-windows` round trip. The toast
    /// tier never comes before 1.5 s whatever the log tier is.
    private static let fast: TimeInterval = 0.3
    private static let slow: TimeInterval = 1.5
    private static let toastFloor: TimeInterval = 1.5

    /// Read an expectation off a command's text, or nil for a command whose
    /// effect the mirror cannot observe — those stay covered by the
    /// reply-arrival probe alone.
    ///
    /// `facts` are the model *at send time*; the "something changed"
    /// expectations bank their baseline from it. A command whose target the
    /// model does not know yields nil rather than a guess: with no baseline
    /// there is nothing honest to compare against later.
    static func derive(from command: String, facts: DiagnosticsFacts) -> CommandExpectation? {
        let tokens = command.split(separator: " ").map(String.init)
        guard let verb = tokens.first else { return nil }
        let target = tokens.firstIndex(of: "-t").flatMap { index -> String? in
            index + 1 < tokens.count ? tokens[index + 1] : nil
        }

        func windowLabel(_ window: DiagnosticsWindowFacts) -> String {
            "window \(window.index) · \(window.name)"
        }

        switch verb {
        case "select-window":
            guard let target, target.hasPrefix("@") else { return nil }
            let window = facts.window(target)
            return CommandExpectation(
                check: .activeWindow(target), command: command,
                title: "Window did not switch",
                subject: window.map(windowLabel) ?? "window \(target)",
                logAfter: fast, toastAfter: toastFloor, kind: "expect-window"
            )

        case "select-pane":
            guard let target, target.hasPrefix("%") else { return nil }
            let window = facts.windowContaining(pane: target)
            return CommandExpectation(
                check: .activePane(target), command: command,
                title: "Pane focus not confirmed",
                subject: "pane \(target)" + (window.map { " in \(windowLabel($0))" } ?? ""),
                logAfter: fast, toastAfter: toastFloor, kind: "expect-pane"
            )

        case "split-window":
            guard let target, target.hasPrefix("%"),
                  let window = facts.windowContaining(pane: target) else { return nil }
            return CommandExpectation(
                check: .paneCountRises(windowID: window.id, wasPanes: window.paneIDs.count),
                command: command,
                title: "Split did not happen",
                subject: windowLabel(window),
                logAfter: slow, toastAfter: max(slow, toastFloor), kind: "expect-split"
            )

        case "kill-pane":
            guard let target, target.hasPrefix("%"),
                  facts.windowContaining(pane: target) != nil else { return nil }
            return CommandExpectation(
                check: .paneGone(target), command: command,
                title: "Pane did not close",
                subject: "pane \(target)",
                logAfter: slow, toastAfter: max(slow, toastFloor), kind: "expect-kill-pane"
            )

        case "kill-window":
            guard let target, target.hasPrefix("@"),
                  let window = facts.window(target) else { return nil }
            return CommandExpectation(
                check: .windowGone(target), command: command,
                title: "Window did not close",
                subject: windowLabel(window),
                logAfter: slow, toastAfter: max(slow, toastFloor), kind: "expect-kill-window"
            )

        case "new-window":
            return CommandExpectation(
                check: .windowListChanges(wasIDs: Set(facts.windows.map(\.id))),
                command: command,
                title: "Window did not open",
                subject: "new window",
                logAfter: slow, toastAfter: max(slow, toastFloor), kind: "expect-new-window"
            )

        case "resize-pane":
            guard let target, target.hasPrefix("%"),
                  let window = facts.windowContaining(pane: target) else { return nil }
            if tokens.contains("-Z") {
                return CommandExpectation(
                    check: .zoomFlips(windowID: window.id, wasZoomed: window.isZoomed),
                    command: command,
                    title: "Zoom did not toggle",
                    subject: windowLabel(window),
                    logAfter: fast, toastAfter: toastFloor, kind: "expect-zoom"
                )
            }
            guard tokens.contains("-x") || tokens.contains("-y") else { return nil }
            return CommandExpectation(
                check: .layoutChanges(
                    windowID: window.id,
                    wasSaved: window.savedLayout, wasVisible: window.visibleLayout
                ),
                command: command,
                title: "Resize did not apply",
                subject: windowLabel(window),
                logAfter: slow, toastAfter: max(slow, toastFloor), kind: "expect-resize"
            )

        default:
            return nil
        }
    }
}
