//
//  AgentTransitionLog.swift
//  TmuxGUI
//

import Foundation

/// Records every agent state change, with what caused it, one file per tmux
/// window.
///
/// The point is not diagnostics in the usual sense. The two strategies are
/// state machines that were *designed* on paper, and a drawing of a state
/// machine is a claim about behaviour rather than a record of it. This is the
/// record: replay a window's file and you have the machine that actually ran,
/// in order, with its causes — which is the only way to check the two against
/// each other. A log of states with no reasons could not do that job, so the
/// reason is not optional here; it is the reason the file exists.
///
/// Written as JSON Lines: one self-contained object per transition, appended,
/// greppable, and readable a line at a time by anything. A file that has to be
/// parsed whole is a file that a crash truncates into nothing.
@MainActor
enum AgentTransitionLog {
    /// One observed transition.
    struct Entry: Encodable {
        let at: String
        let session: String
        let window: String
        let windowName: String
        let pane: String
        /// Nil for the first state a pane is ever seen in.
        let from: String?
        let to: String
        /// Which strategy decided this — `hook` or `screen`.
        let source: String
        /// The hook event, or the screen rule that matched. `-` when the
        /// deciding strategy could not say, which is itself worth seeing.
        let reason: String
        /// Seconds since the previous transition on this pane, so a replay
        /// shows dwell time without arithmetic.
        let heldFor: Double?
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TmuxGUI/agent-state")
    }

    /// One file per window rather than per pane or per session.
    ///
    /// A window is what the sidebar draws a mark for, so a window is the unit
    /// somebody checking the mark against the log will have in their hand. Pane
    /// ids are in every record, so a multi-pane window is still separable.
    static func fileURL(session: String, window: String, name: String) -> URL {
        // Ids rather than names in the filename — `$2` and `@9` cannot contain a
        // path separator and cannot change under you, and a window renamed
        // mid-session must not start a second file. The name rides inside the
        // records, where it is allowed to change.
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(40)
        return directory.appendingPathComponent(
            "\(session.dropFirst())-\(window.dropFirst())-\(safe).jsonl"
        )
    }

    private static var lastStateByPane = [String: (state: String, at: Date)]()
    private static var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Note a pane's current state. Writes only when it differs from the last
    /// one recorded — the caller may call this as often as it likes.
    static func record(
        paneID: String,
        state: AgentState?,
        reason: String?,
        source: String,
        session: String,
        window: String,
        windowName: String
    ) {
        guard AppSettings.logsAgentTransitions else { return }

        let now = Date()
        let to = state?.rawValue ?? "none"
        let previous = lastStateByPane[paneID]
        guard previous?.state != to else { return }
        lastStateByPane[paneID] = (to, now)

        let entry = Entry(
            at: formatter.string(from: now),
            session: session,
            window: window,
            windowName: windowName,
            pane: paneID,
            from: previous?.state,
            to: to,
            source: source,
            reason: (reason?.isEmpty == false ? reason : nil) ?? "-",
            heldFor: previous.map { now.timeIntervalSince($0.at) }
        )

        guard let data = try? encoder.encode(entry) else { return }
        append(data + Data("\n".utf8), to: fileURL(session: session, window: window, name: windowName))
    }

    /// A pane went away. Recorded rather than dropped: a replay that ends
    /// mid-turn should say whether the agent finished or the pane closed under
    /// it, and those look identical if one of them is silent.
    static func recordPaneClosed(
        paneID: String, session: String, window: String, windowName: String
    ) {
        guard AppSettings.logsAgentTransitions, lastStateByPane[paneID] != nil else { return }
        record(
            paneID: paneID, state: nil, reason: "pane closed", source: "app",
            session: session, window: window, windowName: windowName
        )
        lastStateByPane.removeValue(forKey: paneID)
    }

    private static func append(_ data: Data, to url: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Appending by seeking rather than reading and rewriting: these
            // files are meant to be tailed while the app runs, and a rewrite
            // would break anything watching.
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
