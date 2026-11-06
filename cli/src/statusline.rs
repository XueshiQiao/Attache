//! `attache-cli statusline claude`: Claude Code's status line command.
//!
//! Claude Code starts it on every status line refresh with a JSON snapshot
//! on stdin, and draws whatever it prints. The snapshot is the only place
//! some numbers exist at all (the 5-hour and 7-day usage limits, the cost),
//! so it is kept, per session, in `<state>/claude/<session>/status.json`;
//! then the status line that was configured before runs with the same input
//! and its output is passed through, so the line in the terminal does not
//! change.
//!
//! Two refreshes of one session can overlap and finish in either order. The
//! snapshot's `cost.total_duration_ms` only grows within a session, so a
//! snapshot older than the one on disk is dropped rather than written over
//! it.

use crate::fsutil::{safe_id, write_atomic, Lock};
use crate::paths;
use serde_json::Value;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Set for the wrapped command, so a chain that leads back here (another
/// wrapper that was given this command as its inner one) ends instead of
/// starting itself forever.
const GUARD: &str = "ATTACHE_CLI_STATUSLINE";

pub fn run(args: &[String]) -> i32 {
    let mut input = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut input);
    if std::env::var_os(GUARD).is_some() {
        return 0;
    }
    match args.first().map(String::as_str) {
        Some("claude") => {
            record_claude(&input);
            draw(&input, crate::setup::claude_wrapped_command().as_deref())
        }
        _ => {
            eprintln!("Usage: attache-cli statusline claude");
            2
        }
    }
}

fn record_claude(input: &[u8]) {
    let Ok(snapshot) = serde_json::from_slice::<Value>(input) else {
        return;
    };
    let Some(session) = snapshot
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|s| safe_id(s))
    else {
        return;
    };
    let dir = paths::state_dir().join("claude").join(session);
    // A refresh never waits long: Claude is waiting for the line.
    let Ok(Some(_lock)) = Lock::acquire(&dir.join("status.lock"), Duration::from_millis(200))
    else {
        return;
    };
    let path = dir.join("status.json");
    let stored = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    if let (Some(old), Some(new)) = (stored.as_ref().and_then(duration), duration(&snapshot)) {
        if new < old {
            return;
        }
    }
    let _ = write_atomic(&path, &serde_json::to_vec(&snapshot).unwrap_or_default());
}

fn duration(v: &Value) -> Option<u64> {
    v.get("cost")?.get("total_duration_ms")?.as_u64()
}

/// Runs the status line that was there before with the same input, or
/// draws a plain one when there was none: a configured status line that
/// prints nothing still costs Claude a row.
fn draw(input: &[u8], wrapped: Option<&str>) -> i32 {
    let Some(cmd) = wrapped else {
        let snapshot: Value = serde_json::from_slice(input).unwrap_or(Value::Null);
        let model = snapshot
            .pointer("/model/display_name")
            .and_then(Value::as_str)
            .unwrap_or("");
        println!("{model}");
        return 0;
    };
    let child = Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .env(GUARD, "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn();
    let Ok(mut child) = child else { return 1 };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input);
    }
    child.wait().ok().and_then(|s| s.code()).unwrap_or(1)
}
