//
//  TmuxNotification.swift
//  TmuxGUI
//

import Foundation

/// One line of tmux control mode output, already split off the byte stream.
///
/// Only the notifications this spike acts on get their own case; the rest keep
/// their raw text so the log stays useful while the protocol coverage grows.
enum TmuxNotification {
    /// Start of a command reply block. `number` is tmux's command counter.
    case begin(number: Int)
    /// End of a command reply block; `failed` is true for `%error`.
    case end(number: Int, failed: Bool)

    case output(pane: String, data: Data)
    /// Sent once the attach handshake finishes — see `TmuxControlClient`.
    case sessionChanged(id: String, name: String)
    /// A session was given a new name. The id is not decoration: measured on
    /// tmux 3.6a, this is broadcast to **every** control client on the server,
    /// so a client attached to `$0` is told about `$1` being renamed. A
    /// connection that applied it without checking would take the name of
    /// whichever session was renamed most recently — the same shape of mistake
    /// as reading `%client-session-changed` as an identity.
    case sessionRenamed(session: String, name: String)
    case windowAdd(window: String)
    case windowClose(window: String)
    case windowRenamed(window: String, name: String)
    /// `saved` is the arrangement tmux would return to; `visible` is what it is
    /// showing right now. They differ exactly while a pane is zoomed.
    case layoutChange(window: String, saved: String, visible: String)
    case paused(pane: String)
    case resumed(pane: String)
    case exited(reason: String?)
    case other(verb: String, rest: String)

    /// Parse one line. `line` excludes the trailing newline.
    ///
    /// Takes bytes rather than a `String` because `%output` payloads are not
    /// necessarily valid UTF-8 on their own; see `TmuxOctal`.
    static func parse(line: [UInt8]) -> TmuxNotification? {
        guard line.first == UInt8(ascii: "%") else { return nil }

        // Split off the verb, then keep the remainder as bytes so an %output
        // payload never round-trips through String.
        guard let firstSpace = line.firstIndex(of: UInt8(ascii: " ")) else {
            return decodeVerbOnly(String(decoding: line, as: UTF8.self))
        }
        let verb = String(decoding: line[..<firstSpace], as: UTF8.self)
        let rest = Array(line[(firstSpace + 1)...])

        switch verb {
        case "%output":
            // `%output <pane-id> <value>`; value starts right after the single
            // space and runs to end of line — never trim it, a pane can emit a
            // lone space and that is real output.
            guard let sep = rest.firstIndex(of: UInt8(ascii: " ")) else { return nil }
            let pane = String(decoding: rest[..<sep], as: UTF8.self)
            let payload = Array(rest[(sep + 1)...])
            return .output(pane: pane, data: TmuxOctal.decode(payload))

        case "%begin", "%end", "%error":
            // `%begin <time> <number> <flags>`
            let fields = String(decoding: rest, as: UTF8.self).split(separator: " ")
            guard fields.count >= 2, let number = Int(fields[1]) else { return nil }
            return verb == "%begin"
                ? .begin(number: number)
                : .end(number: number, failed: verb == "%error")

        case "%session-changed":
            // `%session-changed <session-id> <name>` — sent to this client
            // about itself. Deliberately NOT merged with
            // `%client-session-changed`, whose first field is a *client* name:
            // that one is broadcast to every client on the server, so reading
            // it as an identity would leave each connection addressing
            // whichever client moved most recently. Every later command
            // targets this id, so getting it wrong silently points a whole
            // connection at someone else's session.
            let text = String(decoding: rest, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 1)
            guard let id = parts.first else { return nil }
            let name = parts.count > 1 ? String(parts[1]) : ""
            return .sessionChanged(id: String(id), name: name)

        case "%session-renamed":
            // `%session-renamed <session-id> <name>`, same shape as
            // `%session-changed` and a single split so a name with spaces
            // survives — `rename-session 'renamed with spaces'` arrives as one
            // trailing field, verified on 3.6a.
            let text = String(decoding: rest, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 1)
            guard let id = parts.first else { return nil }
            return .sessionRenamed(
                session: String(id), name: parts.count > 1 ? String(parts[1]) : ""
            )

        case "%window-add":
            return .windowAdd(window: String(decoding: rest, as: UTF8.self))
        case "%window-close", "%unlinked-window-close":
            return .windowClose(window: String(decoding: rest, as: UTF8.self))
        case "%window-renamed":
            let text = String(decoding: rest, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 1)
            guard let id = parts.first else { return nil }
            return .windowRenamed(window: String(id), name: parts.count > 1 ? String(parts[1]) : "")
        case "%layout-change":
            // `%layout-change <window-id> <saved> <visible> <flags>`, and the
            // third field is the one to draw. `prefix z` reflows the active
            // pane to the whole window without touching the *saved* layout, so
            // a client reading the second field is told nothing at all about a
            // zoom: measured on tmux 3.6a, zooming a pane in an 80x24 window
            // leaves the saved layout at `...{40x24,0,0,0,39x24,41,0,1}` while
            // the visible one reads `b25e,80x24,0,0,1` and `list-panes` puts
            // the pane at 80x24. Drawing the saved one is forty columns of
            // disagreement with the program inside the pane, which is the
            // wrapped-line corruption this codebase is built to avoid.
            //
            // The saved layout is kept because it is the only free answer to
            // "which panes does this window have" — the visible one lists just
            // the zoomed pane, and a surface set built from that would be torn
            // down and rebuilt on every `prefix z`.
            //
            // Two fields is accepted as well: that is what tmux sent before
            // 2.2, and half an update beats dropping the line.
            //
            // Empty fields are kept when splitting, and that is not a detail.
            // `split` drops them by default, so an empty visible field would
            // slide the *flags* into `parts[2]` and `*Z` would be stored as this
            // window's layout — unparseable, and the app would go on drawing the
            // previous pane tree with no sign anything had gone wrong. It costs
            // one argument to make the field a field, and `TmuxWindow.parse`
            // already had to defend against the same emptiness coming back from
            // `list-windows`; defending on one path and not the other is worse
            // than not defending at all.
            let text = String(decoding: rest, as: UTF8.self)
            //
            // Which also means the leading fields have to be checked for
            // emptiness rather than assumed non-empty, since that is exactly
            // what dropping empties used to do for free.
            let parts = text.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let saved = String(parts[1])
            let visible = parts.count >= 3 ? String(parts[2]) : ""
            return .layoutChange(
                window: String(parts[0]),
                saved: saved,
                visible: visible.isEmpty ? saved : visible
            )
        case "%pause":
            return .paused(pane: String(decoding: rest, as: UTF8.self))
        case "%continue":
            return .resumed(pane: String(decoding: rest, as: UTF8.self))
        case "%exit":
            let reason = String(decoding: rest, as: UTF8.self)
            return .exited(reason: reason.isEmpty ? nil : reason)
        default:
            return .other(verb: verb, rest: String(decoding: rest, as: UTF8.self))
        }
    }

    private static func decodeVerbOnly(_ verb: String) -> TmuxNotification {
        verb == "%exit" ? .exited(reason: nil) : .other(verb: verb, rest: "")
    }
}
