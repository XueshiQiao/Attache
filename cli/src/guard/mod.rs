//! `guard`: keeps private values — IP addresses, email addresses, keys,
//! words the owner names — out of every agent's conversation on this host.
//!
//! Before a model sees anything, each value is swapped for a placeholder
//! such as `⟦ip:7f3a9c⟧`; when the agent uses the placeholder in a command
//! or a file, the real value is put back on this host only. Issue #43 has
//! the plan; `hooks.rs` has what each agent allows; `cli/README.md` the
//! protocol the clients read.
//!
//! The commands the agents' hooks run (`mask`, `restore`, `run`, `hook`)
//! never print a real value except where it is the point: `restore` hands
//! its result to a shell's `eval`, `run` to the command it runs. The ones
//! the clients run read and write the rules and the events; only `reveal`
//! prints values, for the owner's own screen, and it refuses when an agent
//! is the one asking.

mod detect;
mod hooks;
mod install;
mod rules;
mod run;
mod vault;

use crate::input::decode;
use detect::{now, Engine, Verdict};
use rules::Rules;
use serde_json::{json, Value};
use std::io::{Read, Write};
use vault::Vault;

/// This program's own options: those before a `--`, after which the words
/// are a command's and never read as ours.
fn own(args: &[String]) -> &[String] {
    &args[..args.iter().position(|a| a == "--").unwrap_or(args.len())]
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    let args = own(args);
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn has(args: &[String], name: &str) -> bool {
    own(args).iter().any(|a| a == name)
}

fn b64_text(s: &str) -> Option<String> {
    if s == "=" {
        return Some(String::new());
    }
    decode(s).and_then(|b| String::from_utf8(b).ok())
}

fn stdin_all() -> Vec<u8> {
    let mut buf = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buf);
    buf
}

fn refuse(why: &str) -> i32 {
    eprintln!("attache-cli guard: {why}");
    3
}

pub fn run(args: &[String]) -> i32 {
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.as_str(), r),
        None => ("status", &[][..]),
    };
    let agent = flag(rest, "--agent").unwrap_or("unknown");
    let site = flag(rest, "--where").unwrap_or(cmd);
    match cmd {
        "mask" => mask(rest, agent, site),
        "restore" => restore(rest, agent, site),
        "run" => run_command(rest, agent),
        "hook" => match rest.first() {
            Some(name) => hooks::run(name),
            None => refuse("hook needs a name"),
        },
        "test" => test(rest),
        "rules" => rules_cmd(rest),
        "events" => events(rest),
        "reveal" => reveal(rest),
        "vault" => vault_cmd(rest),
        "status" => status(),
        "install" | "uninstall" => {
            let Some(which) = rest.first() else { return refuse("which agent: claude, codex or agy") };
            let r = if cmd == "install" { install::install(which) } else { install::uninstall(which) };
            match r {
                Ok(msg) => println!("{}", json!({"done": true, "agent": which, "message": msg})),
                Err(why) => println!("{}", json!({"done": false, "agent": which, "why": why})),
            }
            0
        }
        "pause" => pause(rest),
        _ => {
            eprintln!(
                "Usage:\n  attache-cli guard mask [--json] [--agent A] [--where W]   (stdin)\n  attache-cli guard restore [--json | --sh <text>] [--agent A]\n  attache-cli guard run [--agent A] [--rules-snapshot <sha256>] --sh <command> | -- <argv>...\n  attache-cli guard hook <claude-pre|claude-post|codex-pre|codex-post|codex-prompt|agy-pre>\n  attache-cli guard test --text <base64>\n  attache-cli guard rules [--set <base64 json>]\n  attache-cli guard events [--limit N] [--clear]\n  attache-cli guard reveal <placeholder>...\n  attache-cli guard vault [--forget <placeholder>... | --forget-all]\n  attache-cli guard status\n  attache-cli guard install|uninstall <claude|codex|agy>\n  attache-cli guard pause <minutes>   (0 resumes)"
            );
            2
        }
    }
}

/// Masking for the agents' hooks. Plain: stdin to stdout. `--json`:
/// `{"texts":[…]}` in, `{"texts":[…],"blocked":bool}` out. Any failure
/// prints nothing on stdout and exits non-zero, so a caller that pipes it
/// never gets the text through unmasked.
fn mask(args: &[String], agent: &str, site: &str) -> i32 {
    let input = stdin_all();
    let mut engine = match Engine::load() {
        Ok(e) => e,
        Err(why) => return refuse(&why),
    };
    let out = if has(args, "--json") {
        let Ok(v) = serde_json::from_slice::<Value>(&input) else { return refuse("expected {\"texts\":[…]}") };
        let Some(texts) = v.get("texts").and_then(Value::as_array) else { return refuse("expected {\"texts\":[…]}") };
        let mut blocked = false;
        let mut out = Vec::with_capacity(texts.len());
        for t in texts {
            let (m, b) = engine.mask_str(t.as_str().unwrap_or(""));
            blocked |= b;
            out.push(m);
        }
        let mut line = json!({"texts": out, "blocked": blocked}).to_string();
        line.push('\n');
        line.into_bytes()
    } else {
        engine.mask(&input).0
    };
    if let Err(why) = engine.finish(agent, site) {
        return refuse(&why);
    }
    let _ = std::io::stdout().write_all(&out);
    0
}

fn restore(args: &[String], agent: &str, site: &str) -> i32 {
    let mut engine = match Engine::load() {
        Ok(e) => e,
        Err(why) => return refuse(&why),
    };
    let out = if let Some(text) = flag(args, "--sh") {
        engine.restore_str(text).into_bytes()
    } else if has(args, "--json") {
        let Ok(v) = serde_json::from_slice::<Value>(&stdin_all()) else { return refuse("expected {\"texts\":[…]}") };
        let Some(texts) = v.get("texts").and_then(Value::as_array) else { return refuse("expected {\"texts\":[…]}") };
        let out: Vec<String> = texts.iter().map(|t| engine.restore_str(t.as_str().unwrap_or(""))).collect();
        let mut line = json!({"texts": out}).to_string();
        line.push('\n');
        line.into_bytes()
    } else {
        engine.restore(&stdin_all())
    };
    let _ = engine.finish(agent, site);
    let _ = std::io::stdout().write_all(&out);
    0
}

fn run_command(args: &[String], agent: &str) -> i32 {
    let command = if let Some(text) = flag(args, "--sh") {
        run::RunCommand::Shell(text.to_owned())
    } else if let Some(i) = args.iter().position(|a| a == "--") {
        let argv = args[i + 1..].to_vec();
        if argv.is_empty() {
            return refuse("nothing to run");
        }
        run::RunCommand::Argv(argv)
    } else {
        return refuse("run needs --sh <command> or -- <argv>");
    };
    // A hook that wraps a command which will run inside the agent's sandbox
    // names a copy of the rules instead (agy: see `Rules::snapshot`); with
    // the copy missing or changed this refuses, as for an unreadable file.
    let engine = match flag(args, "--rules-snapshot") {
        Some(digest) => Rules::load_snapshot(digest).and_then(Engine::with_rules),
        // Named with no digest after it: not quietly the rules file instead.
        None if has(args, "--rules-snapshot") => Err("--rules-snapshot names no copy".into()),
        None => Engine::load(),
    };
    match engine {
        Ok(engine) => run::run(engine, command, agent),
        Err(why) => {
            eprintln!("Attaché privacy guard: {why}. The command was not run.");
            run::REFUSED
        }
    }
}

fn verdict_name(v: Verdict) -> &'static str {
    match v {
        Verdict::Mask { restore: true } => "mask",
        Verdict::Mask { restore: false } => "mask_only",
        Verdict::Block => "block",
        Verdict::Pass => "pass",
    }
}

/// What the rules would do to a text, for the app's "Try it" tab: each find
/// by byte offset (the app holds the text, so no value is printed back),
/// and the masked text. Nothing is recorded or kept.
fn test(args: &[String]) -> i32 {
    let Some(text) = flag(args, "--text").and_then(b64_text) else { return refuse("test needs --text <base64>") };
    let rules = match flag(args, "--rules").and_then(b64_text) {
        Some(json) => match serde_json::from_str::<Rules>(&json) {
            Ok(r) => r,
            Err(e) => return refuse(&e.to_string()),
        },
        None => match Rules::load() {
            Ok(r) => r,
            Err(why) => return refuse(&why),
        },
    };
    let mut rules = rules;
    // Shows what the rules do, paused or not.
    rules.paused_until = 0;
    rules.enabled = true;
    let key = match vault::key() {
        Ok(k) => k,
        Err(why) => return refuse(&why),
    };
    let mut engine = match Engine::new(rules, key, Vault::load().unwrap_or_default()) {
        Ok(e) => e,
        Err(why) => return refuse(&why),
    };
    let hits = engine.find(text.as_bytes());
    let (masked, blocked) = engine.mask_str(&text);
    let hits: Vec<Value> = hits
        .iter()
        .map(|h| json!({"start": h.start, "end": h.end, "kind": h.kind, "rule": h.rule, "verdict": verdict_name(h.verdict)}))
        .collect();
    let errors: Vec<Value> = engine.errors.iter().map(|(i, why)| json!({"pattern": i, "why": why})).collect();
    println!("{}", json!({"hits": hits, "masked": masked, "blocked": blocked, "errors": errors}));
    0
}

fn rules_cmd(args: &[String]) -> i32 {
    if let Some(b64) = flag(args, "--set") {
        let answer = match b64_text(b64).ok_or("not base64".to_string()).and_then(|j| {
            serde_json::from_str::<Rules>(&j).map_err(|e| e.to_string())
        }) {
            Ok(mut rules) => {
                // A save from a client never moves the pause; `pause` does.
                if let Ok(current) = Rules::load() {
                    rules.paused_until = current.paused_until;
                }
                match rules.save() {
                    Ok(()) => json!({"saved": true}),
                    Err(why) => json!({"saved": false, "why": why}),
                }
            }
            Err(why) => json!({"saved": false, "why": why}),
        };
        println!("{answer}");
        return 0;
    }
    match Rules::load() {
        Ok(rules) => {
            let errors: Vec<Value> = Engine::new(rules.clone(), vec![0; 32], Vault::default())
                .map(|e| e.errors.iter().map(|(i, why)| json!({"pattern": i, "why": why})).collect())
                .unwrap_or_default();
            println!(
                "{}",
                json!({"rules": rules, "errors": errors, "path": rules::path().to_string_lossy(), "now": now()})
            );
        }
        Err(why) => println!("{}", json!({"rules": null, "why": why, "path": rules::path().to_string_lossy()})),
    }
    0
}

fn events(args: &[String]) -> i32 {
    if has(args, "--clear") {
        match vault::clear_events() {
            Ok(()) => println!("{}", json!({"cleared": true})),
            Err(why) => println!("{}", json!({"cleared": false, "why": why})),
        }
        return 0;
    }
    let limit = flag(args, "--limit").and_then(|n| n.parse().ok()).unwrap_or(500);
    println!("{}", json!({"events": vault::recent(limit), "now": now()}));
    0
}

/// Set in the environment of a process an agent started: Claude Code,
/// Codex, agy. `reveal` refuses there. A speed bump, not a wall — an agent
/// can unset a variable — which is fine because whatever an agent's command
/// prints passes through the guard on its way back to the model.
const AGENT_MARKS: [&str; 7] = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "CODEX_THREAD_ID", "CODEX_MANAGED_BY_NPM", "_AGY_CMD", "AI_AGENT"];

fn reveal(args: &[String]) -> i32 {
    if let Some(mark) = AGENT_MARKS.iter().find(|m| std::env::var_os(m).is_some()) {
        println!("{}", json!({"values": {}, "why": format!("refused: asked from inside an agent ({mark} is set)")}));
        return 0;
    }
    let vault = match Vault::load() {
        Ok(v) => v,
        Err(why) => return refuse(&why),
    };
    let mut values = serde_json::Map::new();
    for t in args.iter().filter(|a| a.starts_with('⟦')) {
        if let Some(e) = vault.entries.get(t) {
            values.insert(t.clone(), json!(e.value));
        }
    }
    println!("{}", json!({"values": values}));
    0
}

fn vault_cmd(args: &[String]) -> i32 {
    if has(args, "--forget-all") || has(args, "--forget") {
        let all = has(args, "--forget-all");
        let targets: Vec<String> = args.iter().filter(|a| a.starts_with('⟦')).cloned().collect();
        let r = Vault::update(|v| {
            if all {
                v.entries.clear();
            } else {
                for t in &targets {
                    v.entries.remove(t);
                }
            }
        });
        match r {
            Ok(()) => println!("{}", json!({"forgot": true})),
            Err(why) => println!("{}", json!({"forgot": false, "why": why})),
        }
        return 0;
    }
    match Vault::load() {
        Ok(v) => {
            let entries: Vec<Value> = v
                .entries
                .iter()
                .map(|(t, e)| json!({"token": t, "kind": e.kind, "rule": e.rule, "masked": e.masked, "restore": e.restore, "first": e.first}))
                .collect();
            println!("{}", json!({"entries": entries}));
        }
        Err(why) => println!("{}", json!({"entries": [], "why": why})),
    }
    0
}

fn status() -> i32 {
    let (rules, why) = match Rules::load() {
        Ok(r) => (Some(r), None),
        Err(why) => (None, Some(why)),
    };
    let t = now();
    println!(
        "{}",
        json!({
            "enabled": rules.as_ref().map(|r| r.enabled),
            "active": rules.as_ref().map(|r| r.active(t)),
            "paused_until": rules.as_ref().map(|r| r.paused_until),
            "why": why,
            "now": t,
            "agents": install::status(),
        })
    );
    0
}

fn pause(args: &[String]) -> i32 {
    let Some(minutes) = args.first().and_then(|m| m.parse::<u64>().ok()) else { return refuse("pause <minutes>") };
    let answer = match Rules::load() {
        Ok(mut rules) => {
            rules.paused_until = if minutes == 0 { 0 } else { now() + minutes.min(24 * 60) * 60 };
            match rules.save() {
                Ok(()) => json!({"paused_until": rules.paused_until}),
                Err(why) => json!({"paused_until": null, "why": why}),
            }
        }
        Err(why) => json!({"paused_until": null, "why": why}),
    };
    println!("{answer}");
    0
}
