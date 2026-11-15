//! `guard hook <name>`: what each agent's hooks run, one JSON object in on
//! stdin and one out on stdout.
//!
//! What each agent lets a hook do decides everything here, and was read from
//! the agents' source and then measured (2026-11-15):
//!
//! | | can rewrite a command | can replace a tool's output | can rewrite a prompt |
//! |---|---|---|---|
//! | Claude Code 2.1.325 hooks | yes (`updatedInput`) | yes (`updatedToolOutput`) | no |
//! | Codex 0.164 | only with `permissionDecision: allow` | no (`decision: block` only) | no (block only) |
//! | agy 1.5.9 | yes (`overwrite`) | no (`overwriteResult` is parsed and ignored) | no hook |
//!
//! So for Codex and agy the command is wrapped in `guard run`, which masks
//! the output before the agent reads it. Codex runs its own approval on the
//! command as rewritten (the approval sits in the tool handler, after the
//! hook), so the wrapper is written to read like the command it wraps.
//!
//! Every handler fails closed: when the rules or the vault cannot be read,
//! the tool call is refused with the reason, never let through unmasked.

use super::detect::{placeholder_regex, Engine};
use serde_json::{json, Value};
use std::io::Read;

pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn exe() -> String {
    std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "attache-cli".into())
}

/// The command an agent runs in place of `command`: readable in an approval
/// prompt as the command it wraps, and holding placeholders only.
pub fn wrapped(command: &str, agent: &str) -> String {
    format!("{} guard run --agent {agent} --sh {}", sh_quote(&exe()), sh_quote(command))
}

/// Whether `command` is already one of ours: it must *start* with this
/// binary's own `guard run`, so a command that merely mentions the words
/// (a grep for them) is wrapped like any other.
fn is_wrapped(command: &str) -> bool {
    command.starts_with(&format!("{} guard run --agent ", sh_quote(&exe())))
}

fn has_placeholder(v: &Value) -> bool {
    match v {
        Value::String(s) => placeholder_regex().is_match(s.as_bytes()),
        Value::Array(a) => a.iter().any(has_placeholder),
        Value::Object(o) => o.values().any(has_placeholder),
        _ => false,
    }
}

/// Applies `f` to every string in `v`; true when any changed.
fn map_strings(v: &mut Value, f: &mut dyn FnMut(&str) -> String) -> bool {
    match v {
        Value::String(s) => {
            let new = f(s);
            let changed = new != *s;
            *s = new;
            changed
        }
        Value::Array(a) => a.iter_mut().fold(false, |c, x| map_strings(x, f) | c),
        Value::Object(o) => o.values_mut().fold(false, |c, x| map_strings(x, f) | c),
        _ => false,
    }
}

/// Masks every string in `v` in place: (changed, blocked).
fn mask_value(engine: &mut Engine, v: &mut Value) -> (bool, bool) {
    let mut blocked = false;
    let changed = map_strings(v, &mut |s| {
        let (out, b) = engine.mask_str(s);
        blocked |= b;
        out
    });
    (changed, blocked)
}

/// Text of `v` for a reason the model reads: a string as it is, anything
/// else as JSON.
fn as_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Object(o) if o.len() == 1 => o.values().next().map(as_text).unwrap_or_default(),
        other => other.to_string(),
    }
}

/// Tools of Claude Code whose arguments get real values back.
const CLAUDE_RESTORE: [&str; 9] = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "Grep", "Glob", "LS"];

pub fn run(name: &str) -> i32 {
    let mut input = String::new();
    let _ = std::io::stdin().read_to_string(&mut input);
    let engine = match serde_json::from_str::<Value>(&input) {
        Ok(event) if event.is_object() => Engine::load().map(|e| (e, event)),
        _ => Err("the agent's hook input could not be read".into()),
    };
    let (out, code) = match engine {
        Ok((mut e, event)) => {
            let r = handle(name, &event, &mut e);
            if let Err(why) = e.finish(agent_of(name), "hook") {
                failed(name, &why)
            } else {
                r
            }
        }
        Err(why) => failed(name, &why),
    };
    if let Some(out) = out {
        println!("{out}");
    }
    code
}

fn agent_of(name: &str) -> &'static str {
    match name.split('-').next() {
        Some("claude") => "claude",
        Some("codex") => "codex",
        Some("agy") => "agy",
        _ => "unknown",
    }
}

const WITHHELD: &str = "Attaché privacy guard could not check this, so it was withheld";

/// What each hook answers when the guard itself cannot run.
fn failed(name: &str, why: &str) -> (Option<Value>, i32) {
    let reason = format!("{WITHHELD}: {why}");
    match name {
        "claude-pre" => {
            eprintln!("{reason}");
            (None, 2)
        }
        "claude-post" | "codex-post" | "codex-prompt" => (Some(json!({"decision": "block", "reason": reason})), 0),
        "codex-pre" => (
            Some(json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}})),
            0,
        ),
        "agy-pre" => (Some(json!({"decision": "deny", "reason": reason})), 0),
        _ => (Some(json!({})), 0),
    }
}

pub fn handle(name: &str, event: &Value, engine: &mut Engine) -> (Option<Value>, i32) {
    let active = engine.active();
    let tool = event.get("tool_name").and_then(Value::as_str).unwrap_or("");
    match name {
        // Claude Code without mods (before 2.1.287): settings hooks.
        "claude-pre" => {
            let Some(input) = event.get("tool_input") else { return (None, 0) };
            if !active || !CLAUDE_RESTORE.contains(&tool) || !has_placeholder(input) {
                return (None, 0);
            }
            let mut updated = input.clone();
            if tool == "Bash" {
                let cmd = input.get("command").and_then(Value::as_str).unwrap_or("");
                updated["command"] = json!(restore_in_place(cmd, "claude"));
            } else {
                map_strings(&mut updated, &mut |s| engine.restore_str(s));
            }
            (Some(json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": updated}})), 0)
        }
        "claude-post" => {
            let Some(response) = event.get("tool_response") else { return (None, 0) };
            let mut masked = response.clone();
            let (changed, blocked) = mask_value(engine, &mut masked);
            if blocked {
                return (Some(json!({"decision": "block", "reason": "Attaché privacy guard withheld this result: it matched a block rule."})), 0);
            }
            if !changed {
                return (None, 0);
            }
            (Some(json!({"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": masked}})), 0)
        }

        "codex-pre" => {
            let cmd = event.pointer("/tool_input/command").and_then(Value::as_str).unwrap_or("");
            let bypass = event.get("permission_mode").and_then(Value::as_str) == Some("bypassPermissions");
            // Wrapping answers `allow`. Where Codex asks before each command
            // the wrapped one is asked about all the same, but an approval
            // prompt full of wrappers is worse to read, so a command with
            // nothing to put back is wrapped only where nobody is asked.
            if !active || cmd.is_empty() || is_wrapped(cmd) || !(bypass || placeholder_regex().is_match(cmd.as_bytes())) {
                return (Some(json!({})), 0);
            }
            (
                Some(json!({"hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": {"command": wrapped(cmd, "codex")},
                }})),
                0,
            )
        }
        "codex-post" => {
            let cmd = event.pointer("/tool_input/command").and_then(Value::as_str).unwrap_or("");
            let Some(response) = event.get("tool_response") else { return (Some(json!({})), 0) };
            if is_wrapped(cmd) {
                return (Some(json!({})), 0);
            }
            let mut masked = response.clone();
            let (changed, blocked) = mask_value(engine, &mut masked);
            if blocked {
                return (Some(json!({"decision": "block", "reason": "Attaché privacy guard withheld this result: it matched a block rule."})), 0);
            }
            if !changed {
                return (Some(json!({})), 0);
            }
            // Codex cannot replace a tool's output; a block hands the model
            // this text in its place. Codex's own session file still has the
            // output as it was — said in the app's status for Codex.
            (Some(json!({"decision": "block", "reason": format!("Output after Attaché's privacy guard masked it:\n{}", as_text(&masked))})), 0)
        }
        "codex-prompt" => {
            let prompt = event.get("prompt").and_then(Value::as_str).unwrap_or("");
            let (masked, blocked) = engine.mask_str(prompt);
            if masked == prompt && !blocked {
                return (Some(json!({})), 0);
            }
            let reason = if blocked {
                "Attaché privacy guard stopped this message: it matched a block rule.".to_string()
            } else {
                format!("Attaché privacy guard stopped this message because it holds private values. Send it like this instead (the guard puts the real values back when a command runs):\n\n{masked}")
            };
            (Some(json!({"decision": "block", "reason": reason})), 0)
        }

        "agy-pre" => {
            let allow = json!({"decision": "allow"});
            if !active {
                return (Some(allow), 0);
            }
            let tool = event.pointer("/toolCall/name").and_then(Value::as_str).unwrap_or("");
            let Some(args) = event.pointer("/toolCall/args").and_then(Value::as_object) else {
                return (Some(allow), 0);
            };
            if tool == "run_command" {
                let Some(cmd) = args.get("CommandLine").and_then(Value::as_str) else { return (Some(allow), 0) };
                if is_wrapped(cmd) {
                    return (Some(allow), 0);
                }
                return (Some(json!({"decision": "allow", "overwrite": {"CommandLine": wrapped(cmd, "agy")}})), 0);
            }
            let mut overwrite = serde_json::Map::new();
            for (k, v) in args {
                if has_placeholder(v) {
                    let mut v = v.clone();
                    map_strings(&mut v, &mut |s| engine.restore_str(s));
                    overwrite.insert(k.clone(), v);
                }
            }
            // agy hands what a file or a search holds straight to the model,
            // and no hook can mask it. A file with private values in it is
            // refused, and so is every search over files, with the way to
            // get the same through the guard.
            if tool.contains("grep") || (tool.contains("search") && !tool.contains("web")) {
                return (
                    Some(json!({"decision": "deny", "reason": "Attaché privacy guard: search files with run_command (for example `rg` or `grep`), which masks private values in what it finds."})),
                    0,
                );
            }
            if tool.contains("read") || tool.contains("view") {
                let cwd = event.get("cwd").and_then(Value::as_str).unwrap_or("");
                for key in ["Path", "AbsolutePath", "File", "FilePath", "TargetFile"] {
                    let path = overwrite.get(key).or_else(|| args.get(key)).and_then(Value::as_str);
                    let Some(path) = path else { continue };
                    if let Some(why) = unreadable(engine, path, cwd) {
                        return (
                            Some(json!({"decision": "deny", "reason": format!(
                                "Attaché privacy guard: {} {why}, so it cannot be read this way. Read it with run_command (for example `cat`), which masks private values.",
                                args.get(key).and_then(Value::as_str).unwrap_or(path)
                            )})),
                            0,
                        );
                    }
                }
            }
            if overwrite.is_empty() {
                (Some(allow), 0)
            } else {
                (Some(json!({"decision": "allow", "overwrite": overwrite})), 0)
            }
        }
        _ => {
            eprintln!("attache-cli guard hook: unknown hook {name}");
            (None, 2)
        }
    }
}

/// A Bash command for Claude Code that gets its real values when it runs,
/// in the session's own shell (so a `cd` in it stays), and never holds them
/// in its text.
pub fn restore_in_place(command: &str, agent: &str) -> String {
    format!(
        "__attache_guard=\"$({} guard restore --agent {agent} --sh {})\" && eval \"$__attache_guard\"",
        sh_quote(&exe()),
        sh_quote(command)
    )
}

/// Why a file must not be handed to agy unmasked, if it must not: it holds
/// a private value, or it is too large to check. A path that is not there
/// is let through (the tool will say so itself).
fn unreadable(engine: &Engine, path: &str, cwd: &str) -> Option<&'static str> {
    let mut p = std::path::PathBuf::from(path);
    if let Some(rest) = path.strip_prefix("~/") {
        p = crate::paths::home().join(rest);
    } else if p.is_relative() && !cwd.is_empty() {
        p = std::path::Path::new(cwd).join(p);
    }
    let meta = std::fs::metadata(&p).ok()?;
    if !meta.is_file() {
        return None;
    }
    if meta.len() > 8 << 20 {
        return Some("is too large for the guard to check");
    }
    let bytes = std::fs::read(&p).ok()?;
    engine
        .find(&bytes)
        .iter()
        .any(|h| h.verdict != super::detect::Verdict::Pass)
        .then_some("holds private values")
}

#[cfg(test)]
mod tests {
    use super::super::detect::tests::engine;
    use super::super::rules::Rules;
    use super::*;

    #[test]
    fn claude_post_masks_bash_output() {
        let mut e = engine(Rules::default());
        let ev = json!({"tool_name": "Bash", "tool_response": {"stdout": "host 192.0.2.8", "stderr": "", "interrupted": false}});
        let (out, code) = handle("claude-post", &ev, &mut e);
        assert_eq!(code, 0);
        let out = out.unwrap();
        let stdout = out.pointer("/hookSpecificOutput/updatedToolOutput/stdout").unwrap().as_str().unwrap();
        assert!(stdout.starts_with("host ⟦ip:"), "{stdout}");
        assert_eq!(out.pointer("/hookSpecificOutput/updatedToolOutput/interrupted"), Some(&json!(false)));
    }

    #[test]
    fn claude_pre_restores_through_eval() {
        let mut e = engine(Rules::default());
        let (masked, _) = e.mask_str("192.0.2.8");
        let ev = json!({"tool_name": "Bash", "tool_input": {"command": format!("ping -c1 {masked}")}});
        let (out, _) = handle("claude-pre", &ev, &mut e);
        let cmd = out.unwrap().pointer("/hookSpecificOutput/updatedInput/command").unwrap().as_str().unwrap().to_owned();
        assert!(cmd.contains("guard restore") && cmd.contains(&masked) && !cmd.contains("192.0.2.8"), "{cmd}");
    }

    #[test]
    fn codex_wraps_only_where_nobody_is_asked_or_it_must() {
        let mut e = engine(Rules::default());
        let plain = json!({"tool_name": "Bash", "tool_input": {"command": "ls"}, "permission_mode": "default"});
        assert_eq!(handle("codex-pre", &plain, &mut e).0, Some(json!({})));
        let bypass = json!({"tool_name": "Bash", "tool_input": {"command": "ls"}, "permission_mode": "bypassPermissions"});
        let out = handle("codex-pre", &bypass, &mut e).0.unwrap();
        assert_eq!(out.pointer("/hookSpecificOutput/permissionDecision"), Some(&json!("allow")));
        let cmd = out.pointer("/hookSpecificOutput/updatedInput/command").unwrap().as_str().unwrap();
        assert!(cmd.ends_with("guard run --agent codex --sh 'ls'"), "{cmd}");
    }

    #[test]
    fn codex_post_hands_masked_output_as_a_block() {
        let mut e = engine(Rules::default());
        let ev = json!({"tool_input": {"command": "ifconfig"}, "tool_response": "inet 192.0.2.8"});
        let out = handle("codex-post", &ev, &mut e).0.unwrap();
        assert_eq!(out["decision"], "block");
        assert!(!out["reason"].as_str().unwrap().contains("192.0.2.8"));
    }

    #[test]
    fn agy_wraps_commands_and_restores_file_writes() {
        let mut e = engine(Rules::default());
        let (masked, _) = e.mask_str("192.0.2.8");
        let ev = json!({"toolCall": {"name": "run_command", "args": {"CommandLine": format!("ping {masked}")}}});
        let out = handle("agy-pre", &ev, &mut e).0.unwrap();
        assert_eq!(out["decision"], "allow");
        assert!(out.pointer("/overwrite/CommandLine").unwrap().as_str().unwrap().contains("guard run --agent agy"));
        let ev = json!({"toolCall": {"name": "write_to_file", "args": {"TargetFile": "/tmp/x", "CodeContent": format!("host = {masked}\n")}}});
        let out = handle("agy-pre", &ev, &mut e).0.unwrap();
        assert_eq!(out.pointer("/overwrite/CodeContent"), Some(&json!("host = 192.0.2.8\n")));
        let ev = json!({"toolCall": {"name": "grep_search", "args": {"Query": "x"}}});
        assert_eq!(handle("agy-pre", &ev, &mut e).0.unwrap()["decision"], "deny");
    }

    #[test]
    fn agy_refuses_a_private_file_found_relative_to_its_cwd() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("conf.txt"), "server = 192.0.2.8\n").unwrap();
        std::fs::write(dir.path().join("plain.txt"), "nothing here\n").unwrap();
        let mut e = engine(Rules::default());
        let cwd = dir.path().to_string_lossy();
        let ev = json!({"cwd": cwd, "toolCall": {"name": "view_file", "args": {"AbsolutePath": "conf.txt"}}});
        assert_eq!(handle("agy-pre", &ev, &mut e).0.unwrap()["decision"], "deny");
        let ev = json!({"cwd": cwd, "toolCall": {"name": "view_file", "args": {"AbsolutePath": "plain.txt"}}});
        assert_eq!(handle("agy-pre", &ev, &mut e).0.unwrap()["decision"], "allow");
    }

    #[test]
    fn a_command_that_mentions_the_wrapper_is_still_wrapped() {
        let mut e = engine(Rules::default());
        let ev = json!({"tool_name": "Bash", "tool_input": {"command": "grep ' guard run --agent ' notes"}, "permission_mode": "bypassPermissions"});
        let out = handle("codex-pre", &ev, &mut e).0.unwrap();
        assert!(out.pointer("/hookSpecificOutput/updatedInput/command").is_some());
    }

    #[test]
    fn quoting_survives_sh() {
        let tricky = r#"echo 'it'"'"'s' "$HOME" `x` \"#;
        let out = std::process::Command::new("/bin/sh").arg("-c").arg(format!("printf %s {}", sh_quote(tricky))).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout), tricky);
    }
}
