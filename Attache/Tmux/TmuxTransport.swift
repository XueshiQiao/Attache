//
//  TmuxTransport.swift
//  Attache
//

import Foundation

/// How to reach one machine over ssh: the destination plus the fixed flags
/// every data connection carries.
///
/// `destination` is an `~/.ssh/config` alias or `user@host` — a name ssh
/// resolves, so this app never grows a credentials UI. It is validated rather
/// than trusted for the same reason `TmuxSocket.parse` validates: one consumer
/// of these values is a shell line, and a destination beginning with `-` would
/// be read by ssh as an option even before any shell is involved.
///
/// `BatchMode=yes` on every data connection is a rule, not a preference: the
/// control pipe is the command channel, and an auth prompt written into it
/// corrupts the protocol in both directions. Auth happens once, in the
/// pre-flight that owns the ControlMaster; data connections only ride the
/// master's socket (`ControlMaster=no` + `ControlPath`), so the second full
/// TCP+auth handshake per command that the issue warns about never happens
/// while the master is up.
nonisolated struct SSHTarget: Equatable {
    let destination: String
    /// The ssh binary. A setting (`ssh_path`) because nothing else lets a
    /// test point the whole remote stack at a stand-in, and because not every
    /// machine's ssh is `/usr/bin/ssh`.
    let sshPath: String
    /// The master's socket path, `%C`-based: macOS caps `sun_path` at 104
    /// bytes and `%C` is a fixed-length hash of host, port and user.
    let controlPath: String

    /// Flags for every connection that carries data rather than auth.
    var dataOptions: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ConnectTimeout=5",
        ]
    }

    /// Argv for the pre-flight master itself: no command, no pty, keepalives
    /// on. The keepalives live here and not on data connections because the
    /// data connections are multiplexed channels — the master's TCP session
    /// is the thing that can go silently half-open.
    var masterArgv: [String] {
        [
            sshPath, "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "--", destination,
        ]
    }
}

/// How this app reaches one tmux server: by spawning tmux locally, or by
/// asking ssh to run it on another machine. Everything that used to take the
/// `(tmuxPath, socket)` pair takes one of these, and every place a command
/// line is built asks it rather than assembling argv by hand — the quoting
/// rules below are the kind that look right and are not.
///
/// Two shells stand between this app and a remote tmux. ssh joins the words
/// after the destination with spaces and hands the string to the remote login
/// shell, so every remote word is quoted once (`quotedRemote`). The embedded
/// terminal adds a second layer: its `command` value goes to a *local*
/// `/bin/sh -c`, whose parse must deliver the remote-quoted words intact —
/// so those are quoted again (`shellLine` over words that are already
/// remote-quoted). A session id is `$N`, and each unquoted layer is a shell
/// that would expand it to nothing.
nonisolated struct TmuxTransport: Equatable {
    enum Kind: Equatable {
        case local
        case ssh(SSHTarget)
    }

    let kind: Kind
    /// On the machine tmux runs on. For ssh this defaults to bare `tmux`
    /// and often must not: a non-interactive remote shell has no Homebrew on
    /// its PATH (measured on this machine: `ssh localhost tmux -V` answers
    /// "command not found" while an interactive shell finds it), which is why
    /// `tmux_path` exists per host.
    let tmuxPath: String
    let socket: TmuxSocket

    static func local(tmuxPath: String, socket: TmuxSocket) -> TmuxTransport {
        TmuxTransport(kind: .local, tmuxPath: tmuxPath, socket: socket)
    }

    /// Whether a path tmux reports (`#{pane_current_path}`, a transcript
    /// path, a repository root) names a file this process can open. The
    /// predicate every feature that touches a disk branches on: a remote
    /// path that exists locally too is not "addressable", it is the wrong
    /// file with the right name.
    var pathsAreLocal: Bool { kind == .local }

    var ssh: SSHTarget? {
        if case .ssh(let target) = kind { return target }
        return nil
    }

    // MARK: - Argv builders (for Process)

    /// The control-mode attach: `tmux -C attach -t <id>`, over plain pipes.
    /// `-T` on the ssh form because the control stream is a protocol, and an
    /// alias with `RequestTTY yes` in the user's config would otherwise get
    /// echo and CR mangling stirred into it.
    func controlAttachArgv(sessionID: String) -> [String] {
        tmuxArgv(["-C", "attach", "-t", sessionID], pty: false)
    }

    /// A one-shot tmux command: `list-sessions`, `new-session -d`,
    /// `show-options`, `load-buffer`.
    func oneShotArgv(_ tmuxWords: [String]) -> [String] {
        tmuxArgv(tmuxWords, pty: false)
    }

    /// An arbitrary command on the machine tmux runs on — the hook
    /// installer's write script, `git`, `command -v`. Local means the words
    /// are the argv; there is no shell in the local path.
    func execArgv(_ words: [String]) -> [String] {
        switch kind {
        case .local:
            words
        case .ssh(let target):
            sshPrefix(target, pty: false) + words.map(Self.shellQuote)
        }
    }

    /// The persistent helper: a stateless `sh` read-eval loop bootstrapped as
    /// one argv word, so nothing is installed remotely. The script itself
    /// contains no single quote — `RemoteHelperScript` keeps that promise —
    /// which is what makes the quoting here total rather than hopeful.
    func helperArgv(script: String) -> [String] {
        switch kind {
        case .local:
            ["/bin/sh", "-c", script]
        case .ssh(let target):
            sshPrefix(target, pty: false) + ["sh", "-c", Self.shellQuote(script)]
        }
    }

    // MARK: - Shell lines (for the embedded terminal's `command`)

    /// The content half's `tmux attach`, as the string ghostty hands to a
    /// local `/bin/sh -c`. The ssh form carries `-t`: the remote tmux needs
    /// the pty that ghostty is already providing locally — and it travels
    /// with `TERM=xterm-256color`, because ssh copies the local TERM into
    /// the pty request and the surface's own `xterm-ghostty` is a terminfo
    /// entry most remote machines have never heard of. Seen live: the mini's
    /// tmux answered "missing or unsuitable terminal: xterm-ghostty" and
    /// exited, which ghostty reports as the command failing to launch.
    func attachShellCommand(sessionID: String) -> String {
        let line = Self.shellLine(tmuxArgv(["attach", "-t", sessionID], pty: true))
        return kind == .local ? line : "TERM=xterm-256color " + line
    }

    /// The user's own command text run on the remote machine with
    /// safely-quoted arguments appended — the git tool's per-host lazygit.
    /// The whole remote line travels as *one* ssh argv word: the person
    /// wrote shell text and gets shell text, while the arguments this app
    /// appends (a repository root) are quoted against the remote shell and
    /// again against the local one. nil for the local machine, whose tool
    /// runs without any shell around its path on purpose.
    func remoteToolShellCommand(rawCommand: String, quotedArguments: [String]) -> String? {
        guard case .ssh(let target) = kind else { return nil }
        let remoteLine = ([rawCommand] + quotedArguments.map(Self.shellQuote))
            .joined(separator: " ")
        // The same TERM the remote attach travels with, for the same reason.
        return "TERM=xterm-256color "
            + Self.shellLine(sshPrefix(target, pty: true) + [remoteLine])
    }

    /// An arbitrary command on tmux's machine, as a ghostty `command` string
    /// — the git tool's lazygit. With a pty, because these are programs a
    /// person looks at.
    func execShellCommand(_ words: [String]) -> String {
        switch kind {
        case .local:
            Self.shellLine(words)
        case .ssh(let target):
            Self.shellLine(sshPrefix(target, pty: true) + words.map(Self.shellQuote))
        }
    }

    // MARK: - Descriptions

    /// For failure messages: which server was being asked, in words that tell
    /// the reader how to reach the same server from a terminal.
    var summary: String {
        switch kind {
        case .local:
            socket.summary
        case .ssh(let target):
            "\(socket.summary) on \(target.destination) (over ssh)"
        }
    }

    /// For log lines that need to say which machine, tersely.
    var hostLabel: String {
        switch kind {
        case .local: "local"
        case .ssh(let target): target.destination
        }
    }

    // MARK: - Composition

    private func tmuxArgv(_ words: [String], pty: Bool) -> [String] {
        let tmux = [tmuxPath] + socket.arguments + words
        switch kind {
        case .local:
            return tmux
        case .ssh(let target):
            return sshPrefix(target, pty: pty) + tmux.map(Self.shellQuote)
        }
    }

    /// `--` before the destination so a destination can never be read as an
    /// option, on top of the parse-time refusal of leading `-` — the same
    /// belt-and-braces as ids: remove the category, then also validate.
    private func sshPrefix(_ target: SSHTarget, pty: Bool) -> [String] {
        [target.sshPath, pty ? "-t" : "-T"] + target.dataOptions + ["--", target.destination]
    }

    /// POSIX single-quoting: total for any byte string without NUL. Values
    /// that reach here are still validated upstream — quoting is the second
    /// layer, not the policy.
    static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A local `/bin/sh -c` line that reproduces `argv` exactly.
    static func shellLine(_ argv: [String]) -> String {
        argv.map(shellQuote).joined(separator: " ")
    }
}
