//
//  TmuxSocket.swift
//  Attache
//

import Foundation

/// Which tmux server this app talks to — the `tmux_socket` setting, parsed.
///
/// tmux runs one server per socket, and nothing ties a machine to one server:
/// `tmux -L work` is a second server with its own sessions, invisible to the
/// first. Sending no socket flag does not mean "the default server" either —
/// it means *tmux picks*: `$TMUX` when the app was launched from inside a
/// pane, the default socket otherwise. That stays the default here, as
/// `.standard`; the setting exists for the person whose real sessions live on
/// a named socket, who until it existed could only ever see an empty app.
///
/// The value is validated rather than trusted, because one consumer is not
/// argv: the embedded terminal's attach command is a `/bin/sh -c` line, so a
/// value carrying a single quote could escape the quoting there. Such values
/// are refused outright rather than escaped around — the same reasoning as
/// targeting tmux by id. An unusable value is a startup failure that names
/// the problem, not a silent fall-through to the default server: the person
/// asked for a specific server, and quietly connecting to a different one
/// invites destructive actions on the wrong sessions.
enum TmuxSocket: Equatable {
    /// No flag: tmux resolves the socket from the environment.
    case standard
    /// `tmux -L <name>` — a socket name under tmux's own directory.
    case label(String)
    /// `tmux -S <path>` — a socket file at an explicit path.
    case path(String)

    enum ParseResult: Equatable {
        case socket(TmuxSocket)
        /// The value cannot be used. The reason completes the sentence "The
        /// tmux_socket value in ~/.config/attache.toml <reason>."
        case invalid(reason: String)
    }

    /// Empty is `.standard`; a value with a `/` anywhere is a path, anything
    /// else a name — the same split tmux's own `-L`/`-S` makes, since a
    /// socket name becomes a filename and cannot carry a slash.
    ///
    /// Length is deliberately not checked here: a path past the kernel's
    /// socket limit makes tmux itself answer `File name too long`, and that
    /// error now reaches the startup dialog with tmux's own words in it.
    static func parse(_ raw: String) -> ParseResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .socket(.standard) }
        if trimmed.contains("'") {
            return .invalid(reason: "contains a single quote, which cannot be quoted safely")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return .invalid(reason: "contains a control character")
        }
        return .socket(trimmed.contains("/") ? .path(trimmed) : .label(trimmed))
    }

    /// Argv for every `Process` this app spawns. Global flags, so they must
    /// precede the command word — `tmux list-sessions -L x` is an error.
    var arguments: [String] {
        switch self {
        case .standard: []
        case .label(let name): ["-L", name]
        case .path(let path): ["-S", path]
        }
    }

    /// The same flags for the one consumer that is a shell line rather than
    /// argv: the embedded terminal's `command`. Single-quoted, and safe only
    /// because `parse` refused values carrying a quote. Ends with a space
    /// when non-empty so call sites splice it in front of the command word.
    var shellFragment: String {
        switch self {
        case .standard: ""
        case .label(let name): "-L '\(name)' "
        case .path(let path): "-S '\(path)' "
        }
    }

    /// For failure messages: which server was being asked, in words that tell
    /// the reader how to reach the same server from a terminal.
    var summary: String {
        switch self {
        case .standard: "the default tmux server"
        case .label(let name): "the tmux server named '\(name)' (tmux -L \(name))"
        case .path(let path): "the tmux server on socket \(path) (tmux -S \(path))"
        }
    }
}
