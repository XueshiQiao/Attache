//
//  TmuxRenameString.swift
//  TmuxGUI
//

import Foundation

/// Removes tmux's `ESC k` window-rename sequence from a pane's raw output.
///
/// Control mode hands a client the pane's bytes *before* tmux's own parser has
/// had them. tmux's wiki is explicit: `%output` is "exactly what the
/// application running in the pane sent to tmux" and carries "escape sequences
/// which will be as expected by tmux (so for TERM=screen or TERM=tmux)". So a
/// control-mode client has to emulate a screen/tmux terminal — and libghostty
/// emulates an xterm one.
///
/// Line up the two parsers' escape tables and that gap is one byte wide. The
/// finals that introduce a *string* — bytes that swallow everything after them
/// until a terminator — are `P X ] ^ _ k` for tmux and `P X ] ^ _` for Ghostty.
/// Every other escape final in either table is a one-shot dispatch carrying no
/// payload, and an unknown CSI, OSC, DCS or APC is consumed whole by both. So
/// `k` is the entire difference, and this type is the entire bridge.
///
/// What it costs to skip: Ghostty logs `ESC k` as an unimplemented action, drops
/// it, and returns to ground — where the title behind it is ordinary printable
/// text and gets drawn. With `TERM=tmux-256color`, oh-my-zsh sends one of these
/// before every command (the command's name) and one before every prompt (the
/// working directory), so every command's output arrives with the command name
/// glued to its front and the working directory on the line beneath it.
///
/// Three of the rules below contradict what the sequence looks like, and all
/// three are measured against tmux 3.6a rather than read off the shape:
///
/// - **BEL does not end it.** `printf 'A\ekTITLE\aB'; echo C` leaves `A` alone
///   on the screen: tmux swallows the BEL, the `B`, the `C`, and everything
///   after them until an escape byte arrives. A filter that stopped at BEL
///   would print text that a real `tmux attach` does not.
/// - **Any ESC ends it, and is then reprocessed as a fresh sequence.**
///   `\ekFIRST\ekSECOND\e\\` renames to SECOND, and `A\ekTITLE\e[7mB` draws a
///   reverse-video `B`. So there is no terminator to match — the escape byte
///   simply goes back through the front door, which is also why the trailing
///   `ESC \` may be passed through untouched: Ghostty no-ops a bare ST.
/// - **An unterminated one expires.** tmux arms a five-second timer on entry
///   (`input_start_ground_timer`) and resets its parser when it fires; measured
///   here as output resuming somewhere between three and seven seconds. Without
///   the same deadline, one stray `ESC k` ahead of a plain-text file would eat
///   the entire file, because plain text holds no escape byte to get out on.
///
/// Nothing is buffered and no title is kept, because the name was never ours to
/// apply. What tmux does with it is tmux's business and depends on a tmux
/// option: `allow-rename` is **off** by default on 3.6a, and `input_exit_rename`
/// returns early when it is, so a default server swallows the string and throws
/// the name away. Turn it on and the window is renamed and the rail hears about
/// it through the ordinary notification path. Either way this side does the same
/// thing, and keeping the title here to "help" would be exactly the authored
/// state this codebase exists to not have.
///
/// So the state is one enum and one timestamp, held only for a pane that is
/// mid-sequence; in the ordinary case a pane has no entry at all.
///
/// Known and deliberate: tmux's `esc_enter` state survives a byte in the middle.
/// Its table keeps the state on C0 (dispatching the control character on the
/// way past) and on 0x7f–0xff, so `ESC <C0> k`, `ESC <DEL> k` and `ESC <high> k`
/// are all rename strings to tmux — measured on 3.6a — and none of them is one
/// here, because this looks only at the byte after the escape. Those leak rather
/// than being eaten, which is the safe direction, and nothing emits them: a
/// prompt writes `ESC k` in one piece. Matching tmux would mean holding an
/// unbounded run of bytes and emitting the C0s out from under a held escape —
/// state and reordering, in the one file that can silently delete a user's
/// output. `Tools/RenameStringCheck` pins the current behaviour so the next
/// reader finds a decision rather than an oversight.
struct TmuxRenameString {
    /// `ESC`, the byte every sequence starts with.
    static let escape: UInt8 = 0x1b
    /// `k`, the final that makes it tmux's rename string rather than anything
    /// Ghostty understands.
    static let rename: UInt8 = 0x6b
    /// CAN and SUB. tmux returns to ground on either, and Ghostty draws nothing
    /// for either, so they are passed through rather than eaten.
    static let cancel: UInt8 = 0x18
    static let substitute: UInt8 = 0x1a

    /// tmux's own number, from `input_start_ground_timer`.
    static let expiry: UInt64 = 5_000_000_000

    private enum State {
        /// Not in a sequence. Panes in this state are not stored.
        case ground
        /// An escape byte arrived with nothing after it yet. Held rather than
        /// emitted, because whether it is ours depends on the next byte — and
        /// that byte can be in the next `%output` chunk. Holding one byte is
        /// invisible: a bare escape draws nothing on its own.
        case escape
        /// Mid-rename-string. `since` is what the five-second deadline is
        /// measured from.
        case swallowing(since: UInt64)
    }

    private var states = [String: State]()

    /// The bytes that should reach the pane's surface.
    ///
    /// `now` is injectable so the deadline can be exercised without waiting on
    /// a real clock; the default reads a monotonic one.
    mutating func strip(
        paneID: String,
        from data: Data,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Data {
        let stored = states[paneID]
        var state = stored ?? .ground

        // Resolved once per chunk rather than by a timer per pane. tmux decides
        // this at the instant the timer fires and this decides it when the next
        // bytes arrive, so a chunk straddling the deadline goes one way whole.
        // That only reaches a sequence nobody terminated, which is already the
        // pathological case the deadline exists for.
        if case .swallowing(let since) = state, now >= since, now - since >= Self.expiry {
            state = .ground
        }

        if case .ground = state, !Self.holdsRenameString(data) {
            if stored != nil { states.removeValue(forKey: paneID) }
            return data
        }

        var out = [UInt8]()
        out.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .ground:
                if byte == Self.escape {
                    state = .escape
                } else {
                    out.append(byte)
                }

            case .escape:
                if byte == Self.rename {
                    state = .swallowing(since: now)
                } else {
                    // Not ours, so the held escape goes out ahead of this byte
                    // and the byte is then handled as if it had arrived in
                    // ground — which for a second escape means holding that one
                    // instead. Anything that is not `ESC k` leaves byte for byte.
                    out.append(Self.escape)
                    if byte == Self.escape {
                        state = .escape
                    } else {
                        out.append(byte)
                        state = .ground
                    }
                }

            case .swallowing:
                switch byte {
                case Self.escape:
                    state = .escape
                case Self.cancel, Self.substitute:
                    out.append(byte)
                    state = .ground
                default:
                    break
                }
            }
        }

        if case .ground = state {
            if stored != nil { states.removeValue(forKey: paneID) }
        } else {
            states[paneID] = state
        }
        return Data(out)
    }

    /// Whether a chunk arriving in ground state has anything for the loop above
    /// to do: an `ESC k` pair, or a trailing escape that the next chunk could
    /// turn into one.
    ///
    /// This runs on every chunk on the reader queue, so it allocates nothing and
    /// makes one pass. Testing merely for an escape byte would be wrong by being
    /// right too often — every chunk a TUI produces has one, and each would then
    /// be copied for nothing.
    private static func holdsRenameString(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            var previousWasEscape = false
            for byte in buffer {
                if previousWasEscape, byte == rename { return true }
                previousWasEscape = byte == escape
            }
            return previousWasEscape
        }
    }
}
