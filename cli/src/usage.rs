//! `attache-cli usage [--watch]`: what the person's AI subscriptions have
//! left — Claude, Antigravity (Gemini) and Grok, each window's used percent
//! and when it resets.
//!
//! None of it is worked out here, and none of it is asked from here.
//! AIUsageKit (github.com/XueshiQiao/AIUsageKit) asks each provider's own
//! CLI and keeps the answers in `~/Library/Caches/AIUsageKit/v1/
//! <provider>.json`; this passes those files on.
//!
//! Who asks is the desktop app, on request. Claude keeps its login in the
//! macOS login keychain, and a process that came in over SSH — this one,
//! started by the phone — cannot read that keychain (measured 2026-11-08:
//! `claude auth status --json` → `loggedIn: false`, `security
//! show-keychain-info` → "User interaction is not allowed";
//! XueshiQiao/Attache#39). The desktop app runs in the desktop login, where
//! it works, also with the screen locked. So a watch calls the app's
//! `usage.refresh` over the Unix socket it listens on (`DesktopCallServer`
//! in the app), and the app's AIUsageKit refreshes the files: from the
//! cache when it is young, from the CLIs otherwise, one process on the Mac
//! at a time. The owner's rule (2026-11-08): usage may depend on the desktop
//! app; the phone's core never does. With the app not running, the phone is
//! told so.

use crate::paths;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PROVIDERS: [&str; 3] = ["claude", "antigravity", "grok"];

// ---------------------------------------------------------------- the desktop app

/// `~/.local/state/attache/desktop.sock`, fixed rather than under
/// `$XDG_STATE_HOME`: the app does not see the owner's shell variables, and
/// both sides must name the same file.
fn desktop_socket() -> PathBuf {
    paths::home().join(".local/state/attache/desktop.sock")
}

/// How young an answer the app may give instead of asking again: the app's
/// own polling uses the same, so the two never take turns.
const MAX_AGE: f64 = 240.0;
/// How often a watch calls, while the app answers.
const REFRESH: Duration = Duration::from_secs(300);
/// How soon a watch tries again when the app is not there.
const RETRY: Duration = Duration::from_secs(30);
/// AIUsageKit gives each provider 60 s and runs them side by side; a call
/// waiting behind another process's lock can take another minute.
const CALL_LIMIT: Duration = Duration::from_secs(150);

#[derive(Debug, PartialEq)]
enum Desktop {
    /// The app answered; per provider, what happened.
    Answered(Value),
    /// Nobody listens: the app is not running (or predates the socket).
    NotRunning(String),
    /// It was there and the call went wrong.
    Failed(String),
}

/// One call to the desktop app: a line of JSON out, a line back.
fn call_desktop(socket: &Path, request: &Value, limit: Duration) -> Desktop {
    let mut stream = match UnixStream::connect(socket) {
        Ok(s) => s,
        // No file, or a file nobody listens on: the app is not running.
        // Anything else (a permission refused) is said as what it is.
        Err(e) if matches!(e.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused) => {
            return Desktop::NotRunning(format!("{}: {e}", socket.display()))
        }
        Err(e) => return Desktop::Failed(format!("connecting to {}: {e}", socket.display())),
    };
    let _ = stream.set_read_timeout(Some(limit));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    if let Err(e) = stream.write_all(format!("{request}\n").as_bytes()) {
        return Desktop::Failed(format!("sending: {e}"));
    }
    let mut answer = String::new();
    // An answer is a line of a few hundred bytes; more than this is not one.
    match BufReader::new(stream.take(64 * 1024)).read_line(&mut answer) {
        Ok(0) => Desktop::Failed("the app closed the connection without answering".into()),
        Ok(_) => match serde_json::from_str::<Value>(&answer) {
            Ok(v) if v.get("ok").and_then(Value::as_bool) == Some(true) => Desktop::Answered(v),
            Ok(v) => Desktop::Failed(format!("the app said: {v}")),
            Err(_) => Desktop::Failed(format!("unreadable answer {:?}", answer.trim())),
        },
        Err(e) => Desktop::Failed(format!("waiting for the answer: {e}")),
    }
}

/// Asks the app to refresh, logs what came back, and says it as a line for
/// the client: `{"t":"usage_desktop","state":…,"why":…}`.
fn refresh() -> Value {
    if !cfg!(target_os = "macos") {
        return json!({ "t": "usage_desktop", "state": "unsupported", "why": null });
    }
    let socket = desktop_socket();
    let request = json!({ "call": "usage.refresh", "max_age": MAX_AGE });
    let started = Instant::now();
    let result = call_desktop(&socket, &request, CALL_LIMIT);
    let took = started.elapsed().as_secs_f64();
    let (state, why) = match &result {
        Desktop::Answered(v) => {
            log(&format!("desktop usage.refresh answered in {took:.1}s"));
            if let Some(Value::Object(providers)) = v.get("providers") {
                for (name, what) in providers {
                    log(&format!("desktop {name}: {}", what.as_str().unwrap_or("?")));
                }
            }
            ("ok", None)
        }
        Desktop::NotRunning(why) => {
            log(&format!("desktop app not reachable: {why}"));
            ("not_running", Some(why.clone()))
        }
        Desktop::Failed(why) => {
            log(&format!("desktop usage.refresh failed after {took:.1}s: {why}"));
            ("failed", Some(why.clone()))
        }
    };
    json!({ "t": "usage_desktop", "state": state, "why": why })
}

// ---------------------------------------------------------------- the log

/// `<state>/usage/`, where `usage.log` is.
fn log_dir() -> PathBuf {
    paths::state_dir().join("usage")
}

/// `usage.log` is moved to `usage.log.1` past this, replacing the one
/// before, so the two together never pass twice it.
const LOG_LIMIT: u64 = 1 << 20;

/// Appends a line to `usage.log`: every watch's start and end with the
/// context it ran in, and every call to the desktop app with its answer,
/// each provider's error word for word. Several processes write it at once;
/// each line is one `write` on a file opened for appending, which the
/// kernel keeps whole.
fn log(line: &str) {
    use std::io::Write;
    let dir = log_dir();
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("usage.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > LOG_LIMIT) {
        let _ = std::fs::rename(&path, dir.join("usage.log.1"));
    }
    let text = format!("{} [{}] {line}\n", format_iso(now_epoch()), std::process::id());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(text.as_bytes());
    }
}

/// Where this process came from: over SSH or not, its parent, `PATH`, and
/// `launchctl managername` — kept for the record, though measured
/// 2026-11-08 it says `Background` both over SSH and inside a tmux server
/// started from the desktop, so it does not tell whether the login keychain
/// is reachable.
fn context() -> String {
    let session = Command::new("launchctl")
        .arg("managername")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "?".into());
    // SAFETY: getppid cannot fail.
    let ppid = unsafe { libc::getppid() };
    let parent = Command::new("ps")
        .args(["-o", "comm=", "-p", &ppid.to_string()])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default();
    format!(
        "attache-cli {} session={session} ppid={ppid} parent={parent} ssh={} tmux={} PATH={}",
        env!("CARGO_PKG_VERSION"),
        if std::env::var_os("SSH_CONNECTION").is_some() { "yes" } else { "no" },
        if std::env::var_os("TMUX").is_some() { "yes" } else { "no" },
        std::env::var("PATH").unwrap_or_default()
    )
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// `2026-11-08T14:42:37Z`.
fn format_iso(t: u64) -> String {
    let days = (t / 86_400) as i64;
    let secs = t % 86_400;
    // Civil date from days (Howard Hinnant's algorithm), the inverse of
    // the one in `time::parse_iso`.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", secs / 3600, secs % 3600 / 60, secs % 60)
}

// ---------------------------------------------------------------- the files

/// `~/Library/Caches/AIUsageKit/v1`, where AIUsageKit keeps one file per
/// provider (`SharedCache.swift`).
fn cache_dir() -> PathBuf {
    paths::home().join("Library/Caches/AIUsageKit/v1")
}

/// A provider's line from AIUsageKit's file, or `None` when there is no
/// file, it is not one, or it holds neither an answer nor a failure. Fields are renamed to this program's style and
/// dates become epoch seconds; nothing is worked out.
fn line(provider: &str, bytes: &[u8]) -> Option<Value> {
    let r: Value = serde_json::from_slice(bytes).ok()?;
    if r.get("provider")?.as_str()? != provider {
        return None;
    }
    let date = |v: Option<&Value>| v.and_then(Value::as_str).and_then(crate::time::parse_iso);
    let stored_at = date(r.get("storedAt"));
    let fetched_at = date(r.get("fetchedAt"));
    let source = r.get("source").and_then(Value::as_str);
    let mut v = json!({ "t": "usage", "provider": provider });
    // AIUsageKit's own test for a record that holds an answer (`hasSnapshot`).
    let answered = stored_at.is_some() && fetched_at.is_some() && source.is_some();
    if answered {
        let windows: Vec<Value> = r
            .get("windows")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|w| {
                json!({
                    "id": w.get("id"),
                    "title": w.get("title"),
                    "group": w.get("group"),
                    "kind": w.get("kind"),
                    "used_percent": w.get("usedPercent"),
                    "resets_at": date(w.get("resetsAt")),
                    "window_seconds": w.get("windowSeconds"),
                })
            })
            .collect();
        v["plan"] = json!(r.get("plan").and_then(Value::as_str));
        v["source"] = json!(source);
        v["fetched_at"] = json!(fetched_at);
        v["stored_at"] = json!(stored_at);
        v["windows"] = Value::Array(windows);
    }
    // The last attempt failed: `writeSuccess` clears `lastErrorKind` and
    // `writeFailure` sets it, so its presence says so on its own. Comparing
    // times would miss a failure in the same second as the success, which
    // is all the precision the file has.
    let failed = r.get("lastErrorKind").and_then(Value::as_str);
    if let Some(kind) = failed {
        v["error"] = json!(kind);
        v["failed_at"] = json!(date(r.get("lastAttemptAt")));
    }
    (answered || failed.is_some()).then_some(v)
}

fn read_line(provider: &str) -> Option<Value> {
    let bytes = std::fs::read(cache_dir().join(format!("{provider}.json"))).ok()?;
    line(provider, &bytes)
}

// ---------------------------------------------------------------- commands

pub fn run(args: &[String]) -> i32 {
    match args {
        [] => {
            // Written as `--watch` writes, so a reader that went away ends
            // this quietly instead of in a panic on the closed pipe.
            let mut out = crate::follow::Out::default();
            log(&format!("usage run: {}", context()));
            out.send(refresh());
            for p in PROVIDERS {
                if let Some(v) = read_line(p) {
                    out.send(v);
                }
            }
            0
        }
        [w] if w == "--watch" => run_watch(),
        _ => {
            eprintln!("Usage: attache-cli usage [--watch]");
            2
        }
    }
}

/// `usage --watch`:
///
/// ```text
/// {"t":"usage_desktop","state":…}  ok, not_running, failed (with why), unsupported off macOS
/// {"t":"usage","provider":…}       one provider's numbers, whenever its file changed
/// ```
///
/// The files are read every 2 s, so an answer written by anyone — the app
/// on this watch's request, on another phone's, or on its own timer — goes
/// out within seconds. The app is called at once and then every five
/// minutes (every 30 s while it is not there), on a thread of its own,
/// since a call can take a minute. Runs until stdin ends, with the
/// heartbeat on stderr that `agents --watch` has.
fn run_watch() -> i32 {
    log(&format!("watch started: {}", context()));
    let gone = Arc::new(AtomicBool::new(false));
    crate::follow::watch_stdin(gone.clone());
    let out = Arc::new(Mutex::new(crate::follow::Out::default()));
    {
        let out = out.clone();
        std::thread::spawn(move || {
            let mut last: Option<Value> = None;
            loop {
                let v = refresh();
                let state = v["state"].as_str().unwrap_or("").to_owned();
                if last.as_ref() != Some(&v) {
                    out.lock().unwrap().send(v.clone());
                    last = Some(v);
                }
                match state.as_str() {
                    "unsupported" => return,
                    "ok" => std::thread::sleep(REFRESH),
                    _ => std::thread::sleep(RETRY),
                }
            }
        });
    }
    let mut last: Vec<Option<String>> = vec![None; PROVIDERS.len()];
    let mut beat = Instant::now();
    loop {
        for (i, p) in PROVIDERS.into_iter().enumerate() {
            // A file that went away (or stopped being one) after its numbers
            // were sent is said too, as a line with no numbers, or the client
            // would keep showing them.
            let v = match read_line(p) {
                Some(v) => v,
                None if last[i].is_some() => json!({ "t": "usage", "provider": p }),
                None => continue,
            };
            let text = v.to_string();
            if last[i].as_deref() != Some(text.as_str()) {
                out.lock().unwrap().send(v);
                last[i] = Some(text);
            }
        }
        std::thread::sleep(Duration::from_secs(2));
        if gone.load(Ordering::SeqCst) {
            log("watch ended: stdin closed (the client went away)");
            return 0;
        }
        if beat.elapsed() >= crate::follow::HEARTBEAT {
            beat = Instant::now();
            let mut err = std::io::stderr();
            if err.write_all(b".").and_then(|_| err.flush()).is_err() {
                log("watch ended: stderr closed (the channel is gone)");
                return 0;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WRITTEN: &str = r#"{
  "fetchedAt" : "2026-11-08T05:07:48Z",
  "fetchedBy" : "Attache:9842",
  "lastAttemptAt" : "2026-11-08T05:07:48Z",
  "plan" : "Max",
  "provider" : "claude",
  "source" : "claude.cli",
  "storedAt" : "2026-11-08T05:07:48Z",
  "windows" : [
    { "id" : "claude.session", "kind" : "session", "resetsAt" : "2026-11-08T09:50:00Z",
      "title" : "5-hour", "usedPercent" : 0, "windowSeconds" : 18000 },
    { "group" : "Fable", "id" : "claude.weekly.fable", "kind" : "weekly",
      "resetsAt" : "2026-11-11T21:00:00Z", "title" : "Fable only", "usedPercent" : 2,
      "windowSeconds" : 604800 }
  ]
}"#;

    #[test]
    fn passes_on_the_file_aiusagekit_wrote() {
        let v = line("claude", WRITTEN.as_bytes()).unwrap();
        assert_eq!(v["t"], "usage");
        assert_eq!(v["plan"], "Max");
        assert_eq!(v["stored_at"], 1_794_114_468);
        assert_eq!(v["windows"][0]["id"], "claude.session");
        assert_eq!(v["windows"][0]["used_percent"], 0);
        assert_eq!(v["windows"][0]["resets_at"], 1_794_131_400);
        assert_eq!(v["windows"][1]["group"], "Fable");
        assert!(v.get("error").is_none());
        // Another provider's file, or not JSON at all, is no line.
        assert!(line("grok", WRITTEN.as_bytes()).is_none());
        assert!(line("claude", b"").is_none());
    }

    #[test]
    fn a_failure_shows_while_lasterrorkind_is_there() {
        // `writeFailure` after a success: the numbers stay, with the
        // failure, even within the same second as the success.
        let failed = WRITTEN.replace("\"plan\"", "\"lastErrorKind\" : \"timeout\",\n  \"plan\"");
        let v = line("claude", failed.as_bytes()).unwrap();
        assert_eq!(v["error"], "timeout");
        assert_eq!(v["failed_at"], 1_794_114_468);
        assert_eq!(v["windows"].as_array().unwrap().len(), 2);
        // `writeSuccess` clears it: no failure.
        assert!(line("claude", WRITTEN.as_bytes()).unwrap().get("error").is_none());
        // Never succeeded: a failure and no numbers.
        let never = r#"{"provider":"grok","windows":[],"lastAttemptAt":"2026-11-08T05:20:00Z","lastErrorKind":"failed"}"#;
        let v = line("grok", never.as_bytes()).unwrap();
        assert_eq!(v["error"], "failed");
        assert!(v.get("windows").is_none());
    }

    #[test]
    fn only_a_real_answer_counts_as_one() {
        // A null where AIUsageKit's `hasSnapshot` wants a value.
        let null_source = WRITTEN.replace("\"claude.cli\"", "null");
        assert!(line("claude", null_source.as_bytes()).is_none());
        let bad_date = WRITTEN.replace("\"fetchedAt\" : \"2026-11-08T05:07:48Z\"", "\"fetchedAt\" : \"soon\"");
        assert!(line("claude", bad_date.as_bytes()).is_none());
        // Neither an answer nor a failure: nothing to say.
        assert!(line("claude", br#"{"provider":"claude","windows":[]}"#).is_none());
    }

    #[test]
    fn a_call_is_one_line_each_way() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("desktop.sock");
        // Nobody there.
        assert!(matches!(
            call_desktop(&sock, &json!({"call": "ping"}), Duration::from_secs(1)),
            Desktop::NotRunning(_)
        ));
        let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        let server = std::thread::spawn(move || {
            for answer in [r#"{"ok":true,"providers":{"claude":"ok via claude.cli"}}"#, r#"{"ok":false,"error":"no such call: x"}"#, ""] {
                let (conn, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(conn.try_clone().unwrap()).read_line(&mut line).unwrap();
                assert!(line.ends_with('\n'));
                let mut conn = conn;
                if !answer.is_empty() {
                    conn.write_all(format!("{answer}\n").as_bytes()).unwrap();
                }
            }
        });
        let req = json!({"call": "usage.refresh", "max_age": 240.0});
        match call_desktop(&sock, &req, Duration::from_secs(5)) {
            Desktop::Answered(v) => assert_eq!(v["providers"]["claude"], "ok via claude.cli"),
            other => panic!("{other:?}"),
        }
        assert!(matches!(call_desktop(&sock, &req, Duration::from_secs(5)), Desktop::Failed(w) if w.contains("no such call")));
        assert!(matches!(call_desktop(&sock, &req, Duration::from_secs(5)), Desktop::Failed(w) if w.contains("without answering")));
        server.join().unwrap();
    }
}
