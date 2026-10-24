//
//  main.swift
//  TransportCheck
//
//  Cross-check for `TmuxTransport`, in the same spirit as `Tools/ReplyCheck`.
//
//      swiftc -O -o /tmp/transportcheck \
//          Attache/Tmux/TmuxSocket.swift Attache/Tmux/TmuxTransport.swift \
//          Attache/Tmux/HostConfig.swift Attache/Tmux/TmuxVersion.swift \
//          Attache/Tmux/TmuxSessionListing.swift Tools/TransportCheck/main.swift
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

/// Reports the TERM it inherited before its argv: what proves the remote
/// assignment prefix actually reached the far side's environment.
let termDumpPath = writeExecutable("term-dump", """
#!/bin/sh
printf '%s\\0' "TERM=$TERM"
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

/// The way ghostty actually runs a surface's `command` — measured from its
/// own failure report, 2026-08-06: `login -flp <user> /bin/bash --noprofile
/// --norc -c "exec -l <command>"`. The distinction from a plain `sh -c` is
/// not academic: `exec` takes a program word, so a command string with a
/// leading `TERM=…` assignment dies inside this wrapper while passing a
/// plain-shell harness — which is exactly how that bug shipped once. Every
/// surface-command case runs through this shape.
func runGhosttyCommand(_ line: String) -> (words: [String], status: Int32) {
    run(["/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(line)"])
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
    let termSSH = TmuxTransport(kind: .ssh(target), tmuxPath: termDumpPath, socket: pathSocket)
    let out = runGhosttyCommand(termSSH.attachShellCommand(sessionID: "$41"))
    // Through ghostty's own exec -l wrapper, with the "remote shell" (the
    // fake ssh's sh -c) reporting the TERM it inherited: the override must
    // arrive as the remote environment, because ssh copies the local
    // xterm-ghostty into the pty request and most machines have no
    // terminfo entry for it — measured live against the mini, where tmux
    // answered "missing or unsuitable terminal" and exited.
    check("ssh attach delivers TERM=xterm-256color to the far side, via exec -l",
          out.words == ["SSH-DEST=devbox", "TERM=xterm-256color",
                        "-S", "/tmp/my sock/s", "attach", "-t", "$41"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let localSpaced = TmuxTransport.local(tmuxPath: spacedDumpPath, socket: labelSocket)
    let out = runGhosttyCommand(localSpaced.attachShellCommand(sessionID: "$41"))
    check("local attach shell command survives ghostty's wrapper",
          out.words == ["-L", "work", "attach", "-t", "$41"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let out = runShellLine(ssh.execShellCommand([dumpPath, "-p", "/tmp/repo's root"]))
    check("ssh exec shell command survives both shells",
          out.words == ["SSH-DEST=devbox", "-p", "/tmp/repo's root"],
          "got \(out.words.map(\.debugDescription))")
}
do {
    let termSSH = TmuxTransport(kind: .ssh(target), tmuxPath: "tmux", socket: plainSocket)
    let line = termSSH.remoteToolShellCommand(
        rawCommand: TmuxTransport.shellQuote(termDumpPath), quotedArguments: ["-p", "/tmp/r"]
    )!
    let out = runGhosttyCommand(line)
    check("remote tool command delivers TERM and exact arguments, via exec -l",
          out.words == ["SSH-DEST=devbox", "TERM=xterm-256color", "-p", "/tmp/r"],
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
check("version: 3.5 reports pane colours", TmuxVersion(major: 3, minor: 5).supportsPaneColourReports)
check("version: 3.4 does not report pane colours", !TmuxVersion(major: 3, minor: 4).supportsPaneColourReports)
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

// MARK: - The server's version, not the binary's

// `tmux -V` names the binary on disk; every gate is about the running server.
// Measured 2026-10-24: a 3.5a server answered `tmux 3.5a` to the server query
// while the 3.6a binary's `-V` said `tmux 3.6a`.
check("server answer: 3.5a", TmuxVersion.parseServerAnswer("tmux 3.5a") == TmuxVersion(major: 3, minor: 5))
check("server answer: trailing newline", TmuxVersion.parseServerAnswer("tmux 3.6a\n") == TmuxVersion(major: 3, minor: 6))
check("server answer: next-3.7", TmuxVersion.parseServerAnswer("tmux next-3.7") == TmuxVersion(major: 3, minor: 7))
check("server answer: master is newer than any release",
      TmuxVersion.parseServerAnswer("tmux master") == TmuxVersion(major: 99, minor: 0))
check("server answer: empty #{version} is older than 2.4",
      TmuxVersion.parseServerAnswer("tmux ") == TmuxVersion(major: 2, minor: 3))
check("server answer: an error is not a version",
      TmuxVersion.parseServerAnswer("no server running on /private/tmp/tmux-501/default") == nil)
check("server answer: nothing is not a version", TmuxVersion.parseServerAnswer("") == nil)
check("server query asks for the version format",
      TmuxVersion.serverQuery == ["display-message", "-p", "tmux #{version}"])

// The discovery script, executed: through the real ssh rendering and a real
// remote `/bin/sh`, with a stand-in `tmux` first on PATH. The stand-in dumps
// the argv the server query reached it with, so the socket word is compared
// byte for byte — it is user config, and the script may hold no single quote,
// so it is double-quoted with sh's specials escaped.
let fakeTmuxDir = workDir.appendingPathComponent("fake-tmux-bin").path
let argvFile = workDir.appendingPathComponent("tmux-argv").path
let binaryAskedFile = workDir.appendingPathComponent("tmux-binary-asked").path
enum FakeServer { case answers, none, garbage, incompatible, protocolMismatch }
func installFakeTmux(_ server: FakeServer) {
    let reply = switch server {
    case .answers: "echo \"tmux 3.5a\""
    case .none: "echo \"no server running\" >&2; exit 1"
    // `display-message` aliased away: exit 0 and a line that is no version.
    case .garbage: "echo \"hello from an alias\""
    // What a 3.5a binary prints against a 3.6a server.
    case .incompatible: "echo \"server exited unexpectedly\" >&2; exit 1"
    case .protocolMismatch: "echo \"protocol version mismatch (client 9, server 8)\" >&2; exit 1"
    }
    _ = writeExecutable("fake-tmux-bin/tmux", """
    #!/bin/sh
    if [ "$1" = "-V" ]; then : > "\(binaryAskedFile)"; echo "tmux 3.6a"; exit 0; fi
    for a in "$@"; do printf '%s\\0' "$a"; done > "\(argvFile)"
    \(reply)
    """)
}
func runDiscovery(socket: TmuxSocket) -> (lines: [String], argv: [String]) {
    try? FileManager.default.removeItem(atPath: argvFile)
    try? FileManager.default.removeItem(atPath: binaryAskedFile)
    let transport = TmuxTransport(kind: .ssh(target), tmuxPath: "tmux", socket: socket)
    let argv = transport.execArgv(["sh", "-c", TmuxVersion.discoveryScript(socket: socket)])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = fakeTmuxDir + ":/usr/bin:/bin"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    // The ssh stand-in puts `SSH-DEST=devbox` and a NUL in front of the
    // script's first line.
    let body = out.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
    let lines = body.split(separator: "\n").map(String.init)
    let dumped = (FileManager.default.contents(atPath: argvFile) ?? Data())
        .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    return (lines, dumped)
}

installFakeTmux(.answers)
let nastySocket = "attache ver $HOME \"q\" `x` \\b *?[]~!#;&|()<>"
for (label, socket) in [("standard", TmuxSocket.standard), ("nasty label", .label(nastySocket)),
                        ("path with a space", .path("/tmp/sock dir/s"))] {
    let result = runDiscovery(socket: socket)
    check("discovery (\(label)): the server's answer is reported",
          result.lines.contains("server: tmux 3.5a"), result.lines.joined(separator: " | "))
    check("discovery (\(label)): the binary's -V is the last line",
          result.lines.last == "tmux 3.6a", result.lines.joined(separator: " | "))
    check("discovery (\(label)): the socket reached tmux byte for byte",
          result.argv == socket.arguments + TmuxVersion.serverQuery, result.argv.debugDescription)
    check("discovery (\(label)): the path is reported first",
          result.lines.first == fakeTmuxDir + "/tmux", result.lines.joined(separator: " | "))
    check("discovery (\(label)): -V is asked too, to compare",
          FileManager.default.fileExists(atPath: binaryAskedFile))
}
installFakeTmux(.none)
for (label, socket) in [("standard", TmuxSocket.standard), ("nasty label", .label(nastySocket))] {
    let result = runDiscovery(socket: socket)
    check("discovery (\(label)): no server, no server line, -V last",
          result.lines.last == "tmux 3.6a" && !result.lines.contains { $0.hasPrefix("server:") },
          result.lines.joined(separator: " | "))
    check("discovery (\(label)): the server was asked first, on its socket",
          result.argv == socket.arguments + TmuxVersion.serverQuery, result.argv.debugDescription)
}
installFakeTmux(.garbage)
let garbage = runDiscovery(socket: .standard).lines
check("discovery: an answer that is no version is not reported as the server's, as on the Swift side",
      garbage.last == "tmux 3.6a" && !garbage.contains { $0.hasPrefix("server:") },
      garbage.joined(separator: " | "))
installFakeTmux(.incompatible)
let incompatible = runDiscovery(socket: .standard).lines
check("discovery: a binary the server cannot talk to says so",
      incompatible.contains("server: incompatible") && incompatible.last == "tmux 3.6a",
      incompatible.joined(separator: " | "))
installFakeTmux(.protocolMismatch)
let protocolMismatch = runDiscovery(socket: .standard).lines
check("discovery: tmux's own protocol check reads as incompatible too",
      protocolMismatch.contains("server: incompatible"), protocolMismatch.joined(separator: " | "))

check("bare text: a pre-2.4 server query answer is empty", TmuxVersion.bareText("tmux") == "")
check("differs: same version", !TmuxVersion.serverDiffers(serverText: "3.6a", binaryText: "3.6a"))
check("differs: 3.5a server, 3.6a binary", TmuxVersion.serverDiffers(serverText: "3.5a", binaryText: "3.6a"))
check("differs: pre-2.4 server with a pre-2.4 binary is not called a mismatch",
      !TmuxVersion.serverDiffers(serverText: "", binaryText: "2.3"))
check("differs: pre-2.4 server with a binary that knows #{version} is one",
      TmuxVersion.serverDiffers(serverText: "", binaryText: "3.6a"))
check("differs: master on both", !TmuxVersion.serverDiffers(serverText: "master", binaryText: "master"))

// The listing every reconcile reads, four fields since `#{version}` joined.
let listing = TmuxSessionListing.parse(listOutput: """
$0 3.6a  name with spaces
$1 3.6a 3 b
$2   pre-2.4 server
$3 3.6a 1   leading spaces kept
garbage line
""")
check("listing: rows with an id", listing.map(\.id) == ["$0", "$1", "$2", "$3"], listing.map(\.id).description)
check("listing: unset order, name with spaces whole",
      listing.first == TmuxSessionListing(id: "$0", name: "name with spaces", order: nil, serverVersion: "3.6a"))
check("listing: order read", listing.dropFirst().first?.order == 3)
check("listing: empty #{version} is empty, name intact",
      listing.dropFirst(2).first == TmuxSessionListing(id: "$2", name: "pre-2.4 server", order: nil, serverVersion: ""))
check("listing: a name's own leading spaces survive", listing.last?.name == "  leading spaces kept")
check("listing: format matches the parse", TmuxSessionListing.format
      == "#{session_id} #{version} #{@attache_order} #{session_name}")

check("bare text: -V and #{version} compare equal",
      TmuxVersion.bareText("tmux 3.6a") == TmuxVersion.bareText("3.6a\n"))
check("incompatible: what 3.5a prints against a 3.6a server",
      TmuxVersion.meansIncompatibleClient("server exited unexpectedly"))
check("incompatible: tmux's own protocol check",
      TmuxVersion.meansIncompatibleClient("protocol version mismatch (client 7, server 8)"))
check("incompatible: no server is not incompatibility",
      !TmuxVersion.meansIncompatibleClient("no server running on /tmp/tmux-501/default"))

check("fallback: after a non-version answer", TmuxVersion.binaryMightAnswer(afterServerQueryExited: 0))
check("fallback: after tmux's own error (no server)", TmuxVersion.binaryMightAnswer(afterServerQueryExited: 1))
check("no fallback: no tmux at that path", !TmuxVersion.binaryMightAnswer(afterServerQueryExited: 127))
check("no fallback: ssh itself failed", !TmuxVersion.binaryMightAnswer(afterServerQueryExited: 255))
check("no fallback: killed at the deadline", !TmuxVersion.binaryMightAnswer(afterServerQueryExited: 15))

// MARK: - Verdict

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all transport checks passed")
