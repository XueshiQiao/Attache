//
//  AnomalyLog.swift
//  TmuxGUI
//

import Foundation

/// The two diagnostics sinks: `anomalies.log` for "did this ever happen", and
/// one JSON file per anomaly for "why".
///
/// Separate from `TmuxLog` on purpose. That file is the complete command
/// timeline and grows by megabytes a day; this one holds only what went
/// wrong, so it stays small enough to read top to bottom after an incident.
/// Every anomaly is *also* mirrored into `tmux-commands.log` by the caller, so
/// the one-file-holds-the-whole-timeline property survives.
enum AnomalyLog {
    static let directory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TmuxGUI", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("anomalies.log")
    static let snapshotDirectory = directory.appendingPathComponent("anomalies", isDirectory: true)

    /// The thing that reports a problem must not become one: an anomaly storm
    /// writing snapshots unbounded would fill the boot volume it is trying to
    /// help debug. 20 is enough to hold every distinct fault of a bad day.
    static let snapshotCap = 20

    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static var bytesWritten: UInt64 = 0

    /// Same failure-modes-table entry as the snapshot cap: the thing that
    /// reports a problem must not become one, and a flapping fault writes a
    /// pair of lines every few seconds for as long as it flaps. Far smaller
    /// than `TmuxLog`'s 8 MB because this file holds only what went wrong —
    /// at ~200 bytes an anomaly, 2 MB is ten thousand of them, and a history
    /// deeper than that stops being readable, which is this file's one job.
    /// One generation kept, same as `TmuxLog`.
    private static let sizeLimit: UInt64 = 2 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let snapshotStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss-SSS"
        return formatter
    }()

    /// Append one anomaly. `detail` becomes the indented second line, which is
    /// what keeps the first line greppable while still carrying the
    /// disagreement and the snapshot name.
    static func record(kind: String, session: String, line: String, detail: String) {
        let text = "[\(stamp.string(from: Date()))] [\(kind)] [\(session)] \(line)\n"
            + "    \(detail)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let handle = openedHandle() else { return }
        // Logging must never be the reason the app fails — same stance as
        // `TmuxLog`, same `try?`.
        let data = Data(text.utf8)
        try? handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)
        if bytesWritten > sizeLimit { rotate() }
    }

    /// Caller holds `lock`. Mirrors `TmuxLog.rotate`, one generation kept.
    private static func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        let previous = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }

    /// The filename a snapshot will be written under, decided *now*.
    ///
    /// Named ahead of the write because the anomaly line references the file,
    /// and the line must go to disk immediately — the payload waits on a tmux
    /// round trip that on a dead channel never comes, and the line is exactly
    /// the thing that must survive that case.
    ///
    /// Named by time and kind (`21-58-04-311-expect-window.json`) so the
    /// anomaly line and the file find each other by eye.
    static func snapshotName(kind: String) -> String {
        "\(snapshotStamp.string(from: Date()))-\(kind).json"
    }

    /// Write one snapshot under a name from `snapshotName(kind:)`, enforcing
    /// the cap. Safe off the main queue; nothing here touches shared state.
    static func writeSnapshot(named name: String, payload: [String: Any]) {
        let url = snapshotDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: snapshotDirectory, withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url)
        }
        prune()
    }

    /// Drop everything beyond the newest `snapshotCap`. Run at every write and
    /// once at launch, so a crash mid-storm still gets cleaned up next start.
    static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapshotDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
        for stale in sorted.dropFirst(snapshotCap) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Caller holds `lock`.
    private static func openedHandle() -> FileHandle? {
        if let handle { return handle }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        bytesWritten = (try? opened.seekToEnd()) ?? 0
        handle = opened
        return opened
    }
}
