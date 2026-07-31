//
//  TmuxStatusOption.swift
//  TmuxGUI
//

import Foundation

/// tmux's own status line, read as what it is: a tmux option.
///
/// Only the reading lives here. Turning it off is a *user* action — the option
/// is per session, not per client, so hiding the line also hides it from an
/// ordinary `tmux attach` to the same session (checked, man tmux 3.6a), and
/// that is not a decision the app gets to make on its own. The Quick Actions
/// menu ships `set status` for it, which toggles when given no value (measured
/// on 3.6a: three presses gave off, on, off).
///
/// Worth recording, because it is the reason the app once tried to hide the row
/// by drawing around it: turning the option off does **not** make tmux mute.
/// tmux still borrows the bottom line for its messages and prompts — verified
/// 2026-07-30 against a live client, where a `display-message` appeared at the
/// bottom of a window whose `status` was `off`. Clipping the row instead leaves
/// tmux believing it has a status line, so `rename-window`'s input box and
/// `kill-window`'s `y/n` were drawn where nobody could see them.
enum TmuxStatusOption {
    /// How many rows the status line occupies for this session right now.
    ///
    /// `off` is 0, `on` is 1, and tmux also accepts a count up to 5.
    /// `#{status_lines}` would be the obvious format and does not exist on
    /// 3.6a — measured, it expands to nothing — so the option itself is read.
    static func lines(tmuxPath: String, sessionID: String) -> Int {
        switch value(tmuxPath: tmuxPath, sessionID: sessionID, option: "status") {
        case "off": 0
        case "on": 1
        case let other: Int(other) ?? 1
        }
    }

    /// Whether the status line sits above the window's rows rather than below.
    ///
    /// It decides what a click's row *means*. `pane_top` counts from the top of
    /// the window, and the window starts below a top-positioned status line —
    /// so on `status-position top` with two status rows, screen row 5 is window
    /// row 3, and reading it as row 5 lands past a horizontal divider and in
    /// the pane underneath. Which then answers with its own directory, and a
    /// relative link opens the wrong file rather than failing to open.
    static func isAtTop(tmuxPath: String, sessionID: String) -> Bool {
        value(tmuxPath: tmuxPath, sessionID: sessionID, option: "status-position") == "top"
    }

    /// The effective value, session first and then global.
    ///
    /// Both are needed and the second one is not a nicety: `show-options -v -t
    /// <session> status` answers with **nothing at all** for a session that has
    /// never had the option set on it — measured on this machine, where every
    /// session answered empty while the global value was `on`. Reading that as
    /// "on" happens to be right until somebody's `.tmux.conf` says
    /// `set -g status 2`.
    private static func value(tmuxPath: String, sessionID: String, option: String) -> String {
        let session = run(tmuxPath, ["show-options", "-v", "-t", sessionID, option])
        guard session.isEmpty else { return session }
        return run(tmuxPath, ["show-options", "-gv", option])
    }

    private static func run(_ tmuxPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
