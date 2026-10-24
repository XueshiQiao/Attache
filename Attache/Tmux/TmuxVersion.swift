//
//  TmuxVersion.swift
//  Attache
//

import Foundation

/// tmux's version, parsed just far enough to gate features on — the
/// *server's*, asked with `serverQuery`, and `tmux -V` only when there is no
/// server to ask.
///
/// Every gate here is about how the server behaves: how it writes reply
/// blocks, whether it has subscriptions, whether it takes colour reports.
/// `tmux -V` reports the binary on disk, and after an upgrade that is not the
/// server still running. Measured 2026-10-24 with a 3.5a server and the 3.6a
/// binary on an isolated `-L` socket: `-V` said `tmux 3.6a`, `display-message
/// -p 'tmux #{version}'` said `tmux 3.5a`, and the 3.6a client listed that
/// server's sessions without complaint — so going by `-V`, the app would
/// have skipped 3.5's reply decoding and shown every window list empty.
///
/// And the binary has to *be* the server's version, not merely be new
/// enough. Measured 2026-10-24 on isolated sockets, both builds protocol 8:
/// a 3.6a control client attached to a 3.5a server gets no reply at all —
/// not even the handshake — so the rail just stays empty; and a 3.5a control
/// client attached to a 3.6a server **takes the server down**, every session
/// in it. One-shot commands survive the first direction and fail cleanly in
/// the second. So `TmuxServer` makes no control connection while the two
/// differ, and says why.
///
/// The app has never had a version check (issue #5, risk 3): every server it
/// met was the local one the person installed. A `[[host]]` can run anything,
/// and the one hard floor today is `refresh-client -B` — the subscriptions
/// every live badge in the rail arrives over — which is tmux ≥ 3.2, sent
/// fire-and-forget, so an older server fails it *unobservably*.
nonisolated struct TmuxVersion: Equatable, Comparable {
    let major: Int
    let minor: Int

    /// From `tmux -V` output: `tmux 3.5a`, `tmux next-3.6`, `tmux 3.4-rc2`,
    /// `tmux master` (nil — treated as new enough by callers that gate,
    /// because master is newer than any release).
    static func parse(_ output: String) -> TmuxVersion? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("tmux ") else { return nil }
        text = String(text.dropFirst("tmux ".count))
        if text.hasPrefix("next-") { text = String(text.dropFirst("next-".count)) }
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return TmuxVersion(major: major, minor: minor)
    }

    /// The tmux words that ask the running server. `#{version}` is tmux
    /// 2.4's; an older server expands it to nothing.
    static let serverQuery = ["display-message", "-p", "tmux #{version}"]

    /// What `serverQuery` printed when it exited 0. nil when it is not a
    /// version at all — the caller then falls back to `tmux -V`.
    static func parseServerAnswer(_ output: String) -> TmuxVersion? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // `#{version}` expanded to nothing: a server older than 2.4, not the
        // unnumbered build `unnumbered` would otherwise take it for.
        if text == "tmux" { return TmuxVersion(major: 2, minor: 3) }
        return parse(text) ?? unnumbered(text)
    }

    /// A version as one comparable word: `tmux 3.6a` from `-V` and `3.6a`
    /// from `#{version}` both come out `3.6a`.
    /// A pre-2.4 server's empty `#{version}` comes out empty, whichever way
    /// it arrived (`tmux` from the server query, `` from a listing).
    static func bareText(_ answer: String) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "tmux" { return "" }
        return text.hasPrefix("tmux ") ? String(text.dropFirst("tmux ".count)) : text
    }

    /// Whether a server that reports `serverText` (`bareText` form) is a
    /// different version from a binary reporting `binaryText` — the test the
    /// control-connection guard runs. An empty server answer is a server
    /// older than 2.4: certainly different from a binary that knows
    /// `#{version}`, and impossible to tell apart from one that does not, in
    /// which case they are taken to match rather than refusing a pair this
    /// app cannot measure.
    static func serverDiffers(serverText: String, binaryText: String) -> Bool {
        if serverText.isEmpty {
            return (parse("tmux \(binaryText)") ?? unnumbered("tmux \(binaryText)"))
                .map { $0 >= TmuxVersion(major: 2, minor: 4) } ?? false
        }
        return serverText != binaryText
    }

    /// What a client says when it cannot talk to the server it reached.
    /// `server exited unexpectedly` is what a 3.5a client prints against a
    /// 3.6a server — measured 2026-10-24, the server itself lives on through
    /// a one-shot command; `protocol version mismatch` is tmux's own check
    /// when the protocol numbers differ (both of these are protocol 8).
    static func meansIncompatibleClient(_ stderr: String) -> Bool {
        stderr.contains("server exited unexpectedly") || stderr.contains("protocol version mismatch")
    }

    /// Whether `tmux -V` is worth asking after `serverQuery` exited with
    /// `status`. 0 (it answered, but not with a version) and 1 (tmux's own
    /// error — `no server running` among them) are; anything else is a
    /// failure `-V` would only repeat: 127 for no tmux at that path, 255 for
    /// ssh itself, a signal for the probe's deadline. Asking again there
    /// doubles the wait before the same error.
    static func binaryMightAnswer(afterServerQueryExited status: Int32) -> Bool {
        status == 0 || status == 1
    }

    /// `tmux master` and other unnumbered builds: newer than any release.
    static func unnumbered(_ output: String) -> TmuxVersion? {
        output.hasPrefix("tmux ") ? TmuxVersion(major: 99, minor: 0) : nil
    }

    /// Where tmux lives when the draft does not say: `command -v` first —
    /// the conventional ask, honoured whenever the remote shell's PATH has
    /// tmux at all — then the places package managers put it, because a
    /// non-interactive ssh shell usually has none of them on its PATH.
    /// Verified against the mini 2026-08-25: `command -v` came up empty and
    /// `/opt/homebrew/bin/tmux` answered. **No single quotes**: the script
    /// travels as one shell word through `TmuxTransport.shellQuote`, whose
    /// totality is the same promise `RemoteHelperScript` keeps.
    static func discoveryScript(socket: TmuxSocket) -> String {
        // Prints the path, then `server: <answer>` when the server gave a
        // version (`server: incompatible` when this binary cannot talk to
        // it), then `-V` last, always: the probe reports the server's
        // version and whether the binary matches it — see `TmuxVersion` for
        // why it must. The socket rides along because the server is asked;
        // `-V` never needed it. Only an answer starting `tmux` counts, the
        // test `parseServerAnswer` makes, so an aliased `display-message`
        // reads the same here as on the Swift side. Double-quoted with sh's four
        // specials escaped, because the script itself may hold no single
        // quote; `TmuxSocket.parse` has already refused control characters.
        let socketWords = socket.arguments.map { word in
            "\"" + word.reduce(into: "") { out, ch in
                if "\\\"$`".contains(ch) { out.append("\\") }
                out.append(ch)
            } + "\""
        }.joined(separator: " ")
        return """
    p=""
    if command -v tmux >/dev/null 2>&1; then p=$(command -v tmux); fi
    if [ -z "$p" ]; then
      for d in /opt/homebrew/bin /usr/local/bin /usr/bin /home/linuxbrew/.linuxbrew/bin /usr/pkg/bin /snap/bin; do
        if [ -x "$d/tmux" ]; then p="$d/tmux"; break; fi
      done
    fi
    if [ -z "$p" ]; then echo tmux-not-found >&2; exit 127; fi
    echo "$p"
    v=$("$p" \(socketWords) display-message -p "tmux #{version}" 2>&1)
    case "$v" in
      tmux*) echo "server: $v" ;;
      *"server exited unexpectedly"*|*"protocol version mismatch"*) echo "server: incompatible" ;;
    esac
    exec "$p" -V
    """
    }

    /// `refresh-client -B` — the subscription mechanism itself.
    var supportsSubscriptions: Bool {
        self >= TmuxVersion(major: 3, minor: 2)
    }

    /// `refresh-client -r`, a control client telling tmux a pane's OSC 10/11
    /// colours — new in 3.5 per tmux's own CHANGES. See `TmuxPaneColours`.
    var supportsPaneColourReports: Bool {
        self >= TmuxVersion(major: 3, minor: 5)
    }

    /// Whether reply-block lines arrive with control characters escaped as
    /// `\ooo`. Measured 2026-08-04, one command sent to each over a pipe:
    /// 3.5a answers `list-windows` with a literal four-character `\001`
    /// where 3.6a sends the raw byte — so the `\u{01}` field separators this
    /// app relies on never match on an unescaped read. Notifications
    /// (`%subscription-changed` included) carry raw bytes on *both*, so the
    /// decode belongs to reply blocks alone.
    var escapesControlModeReplies: Bool {
        self < TmuxVersion(major: 3, minor: 6)
    }

    static func < (a: TmuxVersion, b: TmuxVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    var text: String { "\(major).\(minor)" }
}
