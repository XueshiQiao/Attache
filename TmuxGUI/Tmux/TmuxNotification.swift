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
    case windowAdd(window: String)
    case windowClose(window: String)
    case windowRenamed(window: String, name: String)
    case layoutChange(window: String, layout: String)
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
            let text = String(decoding: rest, as: UTF8.self)
            let parts = text.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return .layoutChange(window: String(parts[0]), layout: String(parts[1]))
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
