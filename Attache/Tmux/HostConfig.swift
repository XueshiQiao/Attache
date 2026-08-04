//
//  HostConfig.swift
//  Attache
//

import Foundation

/// One `[[host]]` block from `~/.config/attache.toml`, validated: a remote
/// machine whose tmux this app attaches to over ssh.
///
/// ```toml
/// [[host]]
/// name = "mini"                        # what the rail calls it
/// ssh = "me@192.168.1.20"            # an ~/.ssh/config alias, or user@host
/// tmux_path = "/opt/homebrew/bin/tmux" # optional; default "tmux", which a
///                                      # non-interactive shell often lacks
/// tmux_socket = ""                     # optional; same syntax as the global
/// git_tool_command = "lazygit"         # optional; runs on the host
/// remote_open_command = ""             # optional; %h = host, %p = path
/// ```
///
/// Validation follows `TmuxSocket.parse`'s reasoning: refuse rather than
/// escape around, and refuse *loudly* — an unusable block becomes a warning
/// notice naming the field, never a silent skip, because a host that quietly
/// fails to appear reads as data loss to the person who configured it. Unlike
/// `tmux_socket` it is not a startup failure: the local server must come up
/// whether or not a remote one is misconfigured.
nonisolated struct HostConfig: Equatable {
    let name: String
    /// The ssh destination, handed to ssh as an operand (after `--`).
    let destination: String
    let tmuxPath: String
    let socket: TmuxSocket
    /// Overrides the global `git_tool_command` for this host, when set.
    let gitToolCommand: String?
    /// How to open a remote file locally from a ⌘-click: a `/bin/sh -c`
    /// template, `%h` replaced with the ssh destination and `%p` with the
    /// remote path — both already shell-quoted when substituted. Empty means
    /// "probe for a `code` CLI, else say there is nothing configured".
    let remoteOpenCommand: String?

    enum ParseResult: Equatable {
        case host(HostConfig)
        /// The block cannot be used. The reason completes the sentence
        /// "A [[host]] block in ~/.config/attache.toml <reason>."
        case invalid(reason: String)
    }

    /// One raw block, as `SettingsFile` collected it. Unknown keys are
    /// ignored here — they may belong to a newer build, and this file's
    /// contract is that nothing it does not understand gets destroyed or
    /// invented meaning for.
    static func parse(_ fields: [String: String]) -> ParseResult {
        guard let name = fields["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty
        else { return .invalid(reason: "has no name") }
        if let problem = refuse(name, describedAs: "name") { return .invalid(reason: problem) }
        // The rail and every log line qualify sessions by host name; "local"
        // is the one name already taken.
        if name.caseInsensitiveCompare("local") == .orderedSame {
            return .invalid(reason: "is named \"local\", which is reserved for this machine")
        }

        guard let ssh = fields["ssh"]?.trimmingCharacters(in: .whitespaces), !ssh.isEmpty
        else { return .invalid(reason: "(\"\(name)\") has no ssh destination") }
        if let problem = refuse(ssh, describedAs: "ssh destination") {
            return .invalid(reason: "(\"\(name)\") \(problem)")
        }
        // `--` before the destination already stops ssh reading it as an
        // option; refusing the shape too is the same belt-and-braces as ids.
        if ssh.hasPrefix("-") {
            return .invalid(reason: "(\"\(name)\") has an ssh destination beginning with \"-\"")
        }
        if ssh.contains(where: \.isWhitespace) {
            return .invalid(reason: "(\"\(name)\") has whitespace in its ssh destination")
        }

        let tmuxPath = fields["tmux_path"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if let problem = refuse(tmuxPath, describedAs: "tmux_path") {
            return .invalid(reason: "(\"\(name)\") \(problem)")
        }

        let socket: TmuxSocket
        switch TmuxSocket.parse(fields["tmux_socket"] ?? "") {
        case .invalid(let reason):
            return .invalid(reason: "(\"\(name)\") has a tmux_socket that \(reason)")
        case .socket(let parsed):
            socket = parsed
        }

        func optional(_ key: String) -> String? {
            let value = fields[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }

        return .host(HostConfig(
            name: name,
            destination: ssh,
            tmuxPath: tmuxPath.isEmpty ? "tmux" : tmuxPath,
            socket: socket,
            gitToolCommand: optional("git_tool_command"),
            remoteOpenCommand: optional("remote_open_command")
        ))
    }

    /// Parse every block, in file order. Duplicated names are refused past
    /// the first: sessions are keyed by host name, and two hosts sharing one
    /// would silently interleave.
    static func parseAll(_ tables: [[String: String]]) -> (hosts: [HostConfig], problems: [String]) {
        var hosts: [HostConfig] = []
        var problems: [String] = []
        for fields in tables {
            switch parse(fields) {
            case .invalid(let reason):
                problems.append(reason)
            case .host(let host):
                if hosts.contains(where: { $0.name == host.name }) {
                    problems.append("(\"\(host.name)\") repeats a name an earlier block already uses")
                } else {
                    hosts.append(host)
                }
            }
        }
        return (hosts, problems)
    }

    /// The refusals every field shares. Values live one hop from a shell —
    /// `TmuxTransport.shellQuote` is total, but the policy here is the same
    /// as everywhere else in this project: remove the category, then also
    /// quote.
    private static func refuse(_ value: String, describedAs field: String) -> String? {
        if value.contains("'") {
            return "has a \(field) containing a single quote, which cannot be quoted safely"
        }
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "has a \(field) containing a control character"
        }
        return nil
    }
}
