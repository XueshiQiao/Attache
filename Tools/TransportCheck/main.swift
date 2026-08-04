//
//  main.swift
//  TransportCheck
//
//  Cross-check for `TmuxTransport`, in the same spirit as `Tools/ReplyCheck`.
//
//      swiftc -O -o /tmp/transportcheck \
//          Attache/Tmux/TmuxSocket.swift Attache/Tmux/TmuxTransport.swift \
//          Attache/Tmux/HostConfig.swift Attache/Tmux/TmuxVersion.swift \
//          Tools/TransportCheck/main.swift
//      /tmp/transportcheck
//
//  What this file refuses to take on faith is the quoting. A remote command
//  crosses two shells — ssh joins its command words with spaces and hands the
//  string to the remote login shell, and the embedded terminal's `command`
//  goes through a local `/bin/sh -c` first — and a session id is `$N`, which
//  every unquoted layer expands to nothing. So the end-to-end cases here do
//  not compare strings against expectations written by the same hand that
//  wrote the quoting: they *execute* the rendered command through a real
//  `/bin/sh`, with an `ssh` stand-in that does exactly what OpenSSH documents
//  (join the words after the destination with spaces, run them in a shell),
//  and an innermost stand-in that dumps the argv it finally received. If the
//  words that come out are not byte-for-byte the words that went in, the
//  quoting is wrong, whatever it looks like.
//

import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// MARK: - Stand-ins

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("transportcheck-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: workDir)
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

func writeExecutable(_ name: String, _ content: String) -> String {
    let url = workDir.appendingPathComponent(name)
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try! content.write(to: url, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// Prints every argv word NUL-terminated. NUL because it is the one byte an
/// argv word cannot contain, so the dump is unambiguous whatever the words
/// hold.
let dumpPath = writeExecutable("dump", """
#!/bin/sh
for a in "$@"; do printf '%s\\0' "$a"; done
""")

/// In a directory with a space in its name, because a tmux path is user
/// config and the quoting must survive one.
let spacedDumpPath = writeExecutable("space dir/dump", """
#!/bin/sh
for a in "$@"; do printf '%s\\0' "$a"; done
""")

/// What OpenSSH does with a command, reduced to the two documented steps:
/// take the words after the destination, join them with single spaces, and
/// hand the string to a shell on the other side. Flags are skipped the way
/// ssh's getopt would. The destination is dumped first so a test can prove
/// it arrived as an operand and not as an option.
let fakeSSHPath = writeExecutable("fake-ssh", """
#!/bin/sh
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -T|-t|-N) shift ;;
    --) shift; dest="$1"; shift; break ;;
    -*) printf 'unexpected ssh flag %s\\n' "$1" >&2; exit 64 ;;
    *) dest="$1"; shift; break ;;
  esac
done
printf '%s\\0' "SSH-DEST=$dest"
[ $# -eq 0 ] && exit 0
exec /bin/sh -c "$*"
""")

/// Run argv, return stdout split on NUL (dropping the trailing empty piece).
func run(_ argv: [String]) -> (words: [String], status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let words = data.split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    return (Array(words.dropLast()), process.terminationStatus)
}

func runShellLine(_ line: String) -> (words: [String], status: Int32) {
    run(["/bin/sh", "-c", line])
}

// MARK: - shellQuote through a real shell

// Not eyeballed against expected strings: each word goes through `/bin/sh`
// and must come out identical. The nasty ones are the point.
let nastyWords = [
    "plain",
    "two words",
    "$34",
    "a'b",
    "it's got 'two' quotes",
    "#{pane_current_path}",
    "back`tick`",
    "semi;colon && chain",
    "tab\there",
    "newline\nin the middle",
    "trailing space ",
    "-leading-dash",
    "~tilde",
    "*glob*",
    "double \"quotes\"",
    "\\backslash\\",
]
for word in nastyWords {
    let out = runShellLine(TmuxTransport.shellLine([dumpPath, word]))
    check("shellQuote round-trips \(word.debugDescription)", out.words == [word],
          "got \(out.words.map(\.debugDescription))")
}
check("shellQuote of empty word survives",
      runShellLine(TmuxTransport.shellLine([dumpPath, "", "x"])).words == ["", "x"])

// MARK: - Local argv tables

let plainSocket = TmuxSocket.parse("").socketValue!
let labelSocket = TmuxSocket.parse("work").socketValue!
let pathSocket = TmuxSocket.parse("/tmp/my sock/s").socketValue!

extension TmuxSocket.ParseResult {
    var socketValue: TmuxSocket? {
        if case .socket(let socket) = self { return socket }
        return nil
    }
}

let local = TmuxTransport.local(tmuxPath: "/opt/homebrew/bin/tmux", socket: labelSocket)
check("local pathsAreLocal", local.pathsAreLocal)
check("local control attach argv",
      local.controlAttachArgv(sessionID: "$7")
          == ["/opt/homebrew/bin/tmux", "-L", "work", "-C", "attach", "-t", "$7"])
check("local one-shot argv",
      local.oneShotArgv(["list-sessions", "-F", "#{session_id} #{session_name}"])
          == ["/opt/homebrew/bin/tmux", "-L", "work",
              "list-sessions", "-F", "#{session_id} #{session_name}"])
check("local exec argv is the words themselves",
      local.execArgv(["/usr/bin/git", "-C", "/tmp/a b", "status"])
          == ["/usr/bin/git", "-C", "/tmp/a b", "status"])
check("local helper argv is sh -c",
      local.helperArgv(script: "read x") == ["/bin/sh", "-c", "read x"])

// MARK: - SSH argv tables

let target = SSHTarget(
    destination: "devbox",
    sshPath: fakeSSHPath,
    controlPath: "/tmp/cp %C"
)
let ssh = TmuxTransport(kind: .ssh(target), tmuxPath: "tmux", socket: plainSocket)
check("ssh pathsAreLocal is false", !ssh.pathsAreLocal)
check("ssh control attach argv shape",
      ssh.controlAttachArgv(sessionID: "$7")
          == [fakeSSHPath, "-T",
              "-o", "BatchMode=yes",
              "-o", "ControlMaster=no",
              "-o", "ControlPath=/tmp/cp %C",
              "-o", "ConnectTimeout=5",
              "--", "devbox",
              "'tmux'", "'-C'", "'attach'", "'-t'", "'$7'"])
check("master argv carries keepalives and no command",
      target.masterArgv
          == [fakeSSHPath, "-N", "-T",
              "-o", "BatchMode=yes",
              "-o", "ControlMaster=yes",
              "-o", "ControlPath=/tmp/cp %C",
              "-o", "ConnectTimeout=10",
              "-o", "ServerAliveInterval=15",
              "-o", "ServerAliveCountMax=2",
              "--", "devbox"])

// MARK: - End to end: one shell layer (Process → fake ssh → remote sh)

// The transport's remote tmux path is the dump stand-in, so what the "remote
// shell" finally executes reports the argv it was given. The socket with a
// space in its path and the `$7` id are the words that break first.
let sshSpaced = TmuxTransport(kind: .ssh(target), tmuxPath: spacedDumpPath, socket: pathSocket)
do {
    let out = run(sshSpaced.controlAttachArgv(sessionID: "$7"))
    check("ssh control attach delivers exact words remotely",
          out.words == ["SSH-DEST=devbox", "-S", "/tmp/my sock/s", "-C", "attach", "-t", "$7"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let out = run(sshSpaced.oneShotArgv(["load-buffer", "-b", "attache-paste-3", "-"]))
    check("ssh one-shot delivers exact words remotely",
          out.words == ["SSH-DEST=devbox", "-S", "/tmp/my sock/s",
                        "load-buffer", "-b", "attache-paste-3", "-"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let out = run(ssh.execArgv([dumpPath] + nastyWords))
    check("ssh exec delivers every nasty word remotely",
          out.words == ["SSH-DEST=devbox"] + nastyWords,
          "got \(out.words.map(\.debugDescription))")
}

// MARK: - End to end: two shell layers (local sh → fake ssh → remote sh)

do {
    let line = sshSpaced.attachShellCommand(sessionID: "$41")
    // ssh copies the local TERM into the pty request, and xterm-ghostty is
    // a terminfo entry most machines have never installed — measured live:
    // the remote tmux exits with "missing or unsuitable terminal".
    check("ssh attach travels with a TERM every machine knows",
          line.hasPrefix("TERM=xterm-256color "))
    let out = runShellLine(line)
    check("ssh attach shell command survives both shells",
          out.words == ["SSH-DEST=devbox", "-S", "/tmp/my sock/s", "attach", "-t", "$41"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let localSpaced = TmuxTransport.local(tmuxPath: spacedDumpPath, socket: labelSocket)
    let out = runShellLine(localSpaced.attachShellCommand(sessionID: "$41"))
    check("local attach shell command survives the local shell",
          out.words == ["-L", "work", "attach", "-t", "$41"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let out = runShellLine(ssh.execShellCommand([dumpPath, "-p", "/tmp/repo's root"]))
    check("ssh exec shell command survives both shells",
          out.words == ["SSH-DEST=devbox", "-p", "/tmp/repo's root"],
          "got \(out.words.map(\.debugDescription))")
}

// MARK: - End to end: the helper bootstrap

// The script travels as one argv word. Dollars, double quotes and newlines in
// it must reach the remote `sh -c` untouched — the canary computes a value
// that comes out wrong under any mis-quoting.
let canaryScript = """
x="a b"
printf '%s\\0' "CANARY:$x:$((6 * 7)):don\u{2019}t"
"""
do {
    let out = run(TmuxTransport.local(tmuxPath: "tmux", socket: plainSocket)
        .helperArgv(script: canaryScript))
    check("helper bootstrap runs locally",
          out.words == ["CANARY:a b:42:don\u{2019}t"], "got \(out.words)")
}
do {
    let out = run(ssh.helperArgv(script: canaryScript))
    check("helper bootstrap survives ssh",
          out.words == ["SSH-DEST=devbox", "CANARY:a b:42:don\u{2019}t"], "got \(out.words)")
}

// MARK: - HostConfig validation

func parsedHost(_ fields: [String: String]) -> HostConfig? {
    if case .host(let host) = HostConfig.parse(fields) { return host }
    return nil
}

func refusalReason(_ fields: [String: String]) -> String? {
    if case .invalid(let reason) = HostConfig.parse(fields) { return reason }
    return nil
}

do {
    let host = parsedHost([
        "name": "mini", "ssh": "me@192.168.1.20",
        "tmux_path": "/opt/homebrew/bin/tmux", "tmux_socket": "work",
        "git_tool_command": "lazygit", "remote_open_command": "code --remote ssh-remote+%h %p",
        "future_key_this_build_does_not_know": "kept elsewhere, ignored here",
    ])
    check("host: full block parses", host != nil)
    check("host: fields land", host?.name == "mini"
          && host?.destination == "me@192.168.1.20"
          && host?.tmuxPath == "/opt/homebrew/bin/tmux"
          && host?.socket == TmuxSocket.parse("work").socketValue
          && host?.gitToolCommand == "lazygit"
          && host?.remoteOpenCommand == "code --remote ssh-remote+%h %p")
}
do {
    let host = parsedHost(["name": "devbox", "ssh": "devbox"])
    check("host: minimal block gets the defaults",
          host?.tmuxPath == "tmux" && host?.socket == .standard
          && host?.gitToolCommand == nil && host?.remoteOpenCommand == nil)
}
check("host: no name refused", refusalReason(["ssh": "devbox"]) == "has no name")
check("host: no ssh refused", refusalReason(["name": "x"]) != nil)
check("host: reserved name refused", refusalReason(["name": "Local", "ssh": "devbox"]) != nil)
check("host: option-shaped destination refused",
      refusalReason(["name": "x", "ssh": "-oProxyCommand=evil"]) != nil)
check("host: whitespace destination refused",
      refusalReason(["name": "x", "ssh": "host b"]) != nil)
check("host: quote in tmux_path refused",
      refusalReason(["name": "x", "ssh": "h", "tmux_path": "/tmp/o'brien/tmux"]) != nil)
check("host: control char in name refused",
      refusalReason(["name": "x\u{07}", "ssh": "h"]) != nil)
check("host: bad socket refused",
      refusalReason(["name": "x", "ssh": "h", "tmux_socket": "with'quote"]) != nil)
do {
    let (hosts, problems) = HostConfig.parseAll([
        ["name": "a", "ssh": "a1"],
        ["name": "b"],
        ["name": "a", "ssh": "a2"],
    ])
    check("host: parseAll keeps the good, names the bad, refuses the duplicate",
          hosts.map(\.name) == ["a"] && problems.count == 2)
}

// MARK: - TmuxVersion

check("version: 3.6a parses", TmuxVersion.parse("tmux 3.6a") == TmuxVersion(major: 3, minor: 6))
check("version: 3.5a parses", TmuxVersion.parse("tmux 3.5a") == TmuxVersion(major: 3, minor: 5))
check("version: next- builds parse",
      TmuxVersion.parse("tmux next-3.7") == TmuxVersion(major: 3, minor: 7))
check("version: rc suffixes parse",
      TmuxVersion.parse("tmux 3.4-rc2") == TmuxVersion(major: 3, minor: 4))
check("version: master is nil (callers treat unnumbered as newest)",
      TmuxVersion.parse("tmux master") == nil)
check("version: garbage is nil", TmuxVersion.parse("bash: tmux: command not found") == nil)
check("version: 3.1 has no subscriptions",
      TmuxVersion(major: 3, minor: 1).supportsSubscriptions == false)
check("version: 3.2 has subscriptions",
      TmuxVersion(major: 3, minor: 2).supportsSubscriptions == true)
// The boundary the 3.5a defect proved: replies are octal-escaped below 3.6.
// Measured 2026-08-04 — list-windows answered a literal \001 on 3.5a where
// 3.6a sends the raw byte.
check("version: 3.5 escapes control-mode replies",
      TmuxVersion(major: 3, minor: 5).escapesControlModeReplies == true)
check("version: 3.6 does not escape replies",
      TmuxVersion(major: 3, minor: 6).escapesControlModeReplies == false)

// MARK: - Verdict

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all transport checks passed")
