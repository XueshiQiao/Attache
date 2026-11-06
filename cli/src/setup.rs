//! `attache-cli setup` and `attache-cli uninstall`: putting this program
//! into the agents' configs, and taking it out again.
//!
//! For now that is Claude Code's status line. Its `statusLine` object in
//! `settings.json` is recorded in `<state>/claude/statusline.json` and its
//! command replaced by this program's; `statusline` runs the recorded one,
//! and `uninstall` puts the object back as it was.
//!
//! The desktop app wraps the status line the same way
//! (`~/.claude/hooks/tmuxgui-statusline.sh`, its inner command in the
//! `.conf` beside it). Both wrappers pass the input and output through, so
//! they nest in either order; the one thing to avoid is wrapping a chain
//! that already runs this program, which would draw the line twice and,
//! without the guard in `statusline`, loop. So setup reads the desktop
//! wrapper's inner command before deciding.
//!
//! `settings.json` is also written by Claude Code itself (when settings are
//! changed from inside it), and no lock of ours reaches Claude. So this runs
//! only on install and upgrade, reads and writes in one short step, keeps a
//! backup beside the file, and reads the result back.

use crate::fsutil::{write_atomic, Lock};
use crate::paths;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn run_setup() -> i32 {
    report(
        "setup",
        with_lock(|| claude_statusline_install(&our_command())),
    )
}

pub fn run_uninstall() -> i32 {
    report("uninstall", with_lock(claude_statusline_uninstall))
}

fn report(what: &str, result: Result<&'static str, String>) -> i32 {
    match result {
        Ok(outcome) => {
            println!(
                "{}",
                json!({ "command": what, "claude_statusline": outcome })
            );
            0
        }
        Err(e) => {
            println!(
                "{}",
                json!({ "command": what, "claude_statusline": "failed", "error": e })
            );
            1
        }
    }
}

fn with_lock<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    // The phone, the tablet and the desktop can all connect at once and all
    // decide to set up; the second one waits, then finds nothing to do.
    let lock = Lock::acquire(
        &paths::state_dir().join("setup.lock"),
        Duration::from_secs(10),
    )
    .map_err(|e| e.to_string())?;
    let _lock = lock.ok_or("another setup is running")?;
    f()
}

fn settings_path() -> PathBuf {
    paths::claude_dir().join("settings.json")
}

fn record_path() -> PathBuf {
    paths::state_dir().join("claude").join("statusline.json")
}

/// This binary's status line command, by its absolute path, quoted for sh.
pub fn our_command() -> String {
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "attache-cli".into());
    format!("'{}' statusline claude", exe.replace('\'', "'\\''"))
}

fn is_ours(command: &str) -> bool {
    command.contains("attache-cli") && command.contains("statusline")
}

fn command_of(status_line: Option<&Value>) -> Option<&str> {
    status_line?.get("command")?.as_str()
}

/// Whether `command` is the desktop app's wrapper with this program as its
/// inner command.
fn desktop_wraps_us(command: &str) -> bool {
    let Some(script) = command.split_whitespace().find(|w| {
        w.trim_matches(|c| c == '\'' || c == '"')
            .ends_with("tmuxgui-statusline.sh")
    }) else {
        return false;
    };
    let script = expand_home(script.trim_matches(|c| c == '\'' || c == '"'));
    let conf = script.with_file_name("tmuxgui-statusline.conf");
    fs::read_to_string(conf)
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.strip_prefix("INNER=").map(str::to_owned))
        })
        .is_some_and(|inner| is_ours(&inner))
}

fn expand_home(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => paths::home().join(rest),
        None => PathBuf::from(path),
    }
}

fn read_settings(path: &Path) -> Result<Map<String, Value>, String> {
    match fs::read(path) {
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
            Ok(Value::Object(map)) => Ok(map),
            // Never written over: a file Claude cannot read either is the
            // person's to fix, and a guess here would lose their settings.
            _ => Err(format!("{} is not a JSON object", path.display())),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn write_settings(path: &Path, settings: &Map<String, Value>) -> Result<(), String> {
    if path.exists() {
        let epoch = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = path.with_file_name(format!("settings.json.attache-backup-{epoch}"));
        fs::copy(path, backup).map_err(|e| e.to_string())?;
    }
    let mut text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    text.push('\n');
    write_atomic(path, text.as_bytes()).map_err(|e| e.to_string())?;
    // Claude may have written it in the same moment; say so rather than
    // report an install that is not there.
    if read_settings(path)? != *settings {
        return Err("settings.json changed while it was being written".into());
    }
    Ok(())
}

pub fn claude_statusline_install(ours: &str) -> Result<&'static str, String> {
    let path = settings_path();
    let mut settings = read_settings(&path)?;
    let current = settings.get("statusLine").cloned();
    if let Some(cmd) = command_of(current.as_ref()) {
        if is_ours(cmd) {
            if cmd == ours {
                return Ok("already");
            }
            // The binary moved: point at where it is now.
            settings.insert("statusLine".into(), with_command(current.as_ref(), ours));
            write_settings(&path, &settings)?;
            return Ok("updated");
        }
        if desktop_wraps_us(cmd) {
            return Ok("inside-desktop-wrapper");
        }
    }
    let record = json!({ "original": current.clone().unwrap_or(Value::Null) });
    write_atomic(
        &record_path(),
        serde_json::to_string_pretty(&record).unwrap().as_bytes(),
    )
    .map_err(|e| e.to_string())?;
    settings.insert("statusLine".into(), with_command(current.as_ref(), ours));
    write_settings(&path, &settings)?;
    Ok("installed")
}

/// The status line object with its command replaced; anything else in it
/// (padding, …) kept.
fn with_command(current: Option<&Value>, command: &str) -> Value {
    let mut object = current
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    object.insert("type".into(), Value::from("command"));
    object.insert("command".into(), Value::from(command));
    Value::Object(object)
}

pub fn claude_statusline_uninstall() -> Result<&'static str, String> {
    let path = settings_path();
    let mut settings = read_settings(&path)?;
    let ours = command_of(settings.get("statusLine")).is_some_and(is_ours);
    if !ours {
        return Ok("not-installed");
    }
    let original = fs::read(record_path())
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|r| r.get("original").cloned())
        .ok_or("the record of the original status line is missing; see the backups beside settings.json")?;
    match original {
        Value::Null => settings.remove("statusLine"),
        other => settings.insert("statusLine".into(), other),
    };
    write_settings(&path, &settings)?;
    let _ = fs::remove_file(record_path());
    Ok("removed")
}

/// The command that ran before this program took the status line, if any.
pub fn claude_wrapped_command() -> Option<String> {
    let record: Value = serde_json::from_slice(&fs::read(record_path()).ok()?).ok()?;
    let cmd = record.get("original")?.get("command")?.as_str()?;
    (!cmd.trim().is_empty() && !is_ours(cmd)).then(|| cmd.to_owned())
}
