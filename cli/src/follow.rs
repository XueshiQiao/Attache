//! `attache-cli follow <claude|agy> <transcript> [--before <offset>]`: one
//! conversation, read and then followed, as JSON lines on stdout.
//!
//! ```text
//! {"t":"waiting"}                              the file does not exist yet
//! {"t":"hello","protocol":1,"kind":…,"path":…,"start":<offset>,"earlier":<bool>}
//! {"t":"items","from":<n>,"items":[…]}         rows n.. replaced by these
//! {"t":"status",…}                             when what the header shows changed
//! {"t":"switched","path":…}                    the conversation moved to another file
//! ```
//!
//! Rows are sent from the first one that changed, which is almost always
//! the tail: a new reply, a tool's result landing on its call, a rewind
//! cutting the end off. A reread (`hello`) sends them all.
//!
//! The first read takes enough of the end of the file for `MIN_ITEMS` rows,
//! doubling the window until it has them, and only rows cross the link:
//! the bookkeeping that was a third of what the phone used to receive never
//! leaves the host. Earlier history is a new `follow` with `--before` set to
//! the `start` the last one reported.
//!
//! It runs until whoever started it goes: its stdin ends when the SSH
//! channel closes, and a byte to stderr every 15 s catches a channel that
//! went without saying so. It never writes to the transcript.

use crate::agents::agy_model;
use crate::agy_transcript::AgyTranscript;
use crate::chat::{first_change, Item, Said, Transcript};
use crate::claude_transcript::ClaudeTranscript;
use crate::paths;
use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const MIN_ITEMS: usize = 60;
const FIRST_WINDOW: u64 = 512 * 1024;
const MAX_WINDOW: u64 = 64 * 1024 * 1024;
const TICK: Duration = Duration::from_millis(200);
const HEARTBEAT: Duration = Duration::from_secs(15);

pub fn run(args: &[String]) -> i32 {
    let (kind, path, before) = match args {
        [k, p] => (k.as_str(), p.as_str(), None),
        [k, p, flag, n] if flag == "--before" => match n.parse::<u64>() {
            Ok(n) => (k.as_str(), p.as_str(), Some(n)),
            Err(_) => return usage(),
        },
        _ => return usage(),
    };
    if !matches!(kind, "claude" | "agy") || !path.starts_with('/') || !path.ends_with(".jsonl") {
        return usage();
    }
    let gone = Arc::new(AtomicBool::new(false));
    watch_stdin(gone.clone());
    let mut out = Out::default();
    let mut follow = Follow {
        kind,
        path: PathBuf::from(path),
        before,
        out: &mut out,
        gone,
    };
    follow.run();
    0
}

fn usage() -> i32 {
    eprintln!("Usage: attache-cli follow <claude|agy> <transcript.jsonl> [--before <offset>]");
    2
}

/// The SSH channel closing ends stdin; nothing is ever read from it.
fn watch_stdin(gone: Arc<AtomicBool>) {
    thread::spawn(move || {
        let mut buf = [0u8; 256];
        let mut stdin = std::io::stdin();
        while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
        gone.store(true, Ordering::SeqCst);
    });
}

/// stdout, one JSON value a line; a write that fails means nobody is
/// reading any more, and the process ends.
#[derive(Default)]
struct Out {
    last_status: Option<String>,
}

impl Out {
    fn send(&mut self, v: Value) {
        let mut stdout = std::io::stdout().lock();
        if writeln!(stdout, "{v}")
            .and_then(|_| stdout.flush())
            .is_err()
        {
            std::process::exit(0);
        }
    }
}

struct Follow<'a> {
    kind: &'a str,
    path: PathBuf,
    before: Option<u64>,
    out: &'a mut Out,
    gone: Arc<AtomicBool>,
}

fn reader(kind: &str) -> Box<dyn Transcript> {
    match kind {
        "agy" => Box::new(AgyTranscript::new()),
        _ => Box::new(ClaudeTranscript::new()),
    }
}

impl Follow<'_> {
    fn run(&mut self) {
        let mut beat = Instant::now();
        'file: loop {
            // A new session's file appears with its first message.
            let mut said_waiting = false;
            while !self.path.exists() {
                if !said_waiting {
                    self.out.send(json!({ "t": "waiting" }));
                    said_waiting = true;
                }
                if !self.tick(&mut beat) {
                    return;
                }
            }
            let (mut transcript, start, mut offset) =
                load(self.kind, &self.path, self.before.take());
            self.out.send(
                json!({ "t": "hello", "protocol": crate::PROTOCOL, "kind": self.kind,
                                  "path": self.path, "start": start, "earlier": start > 0 }),
            );
            let mut shown: Vec<Item> = transcript.items().to_vec();
            self.out.send(json!({ "t": "items", "from": 0, "items": shown.iter().map(Item::to_json).collect::<Vec<_>>() }));
            self.out.last_status = None;
            let mut pending = Vec::new();
            loop {
                self.send_status(&transcript.said());
                if let Some(next) = transcript
                    .continued_in()
                    .filter(|n| crate::fsutil::safe_id(n))
                {
                    self.path = self.path.with_file_name(format!("{next}.jsonl"));
                    self.out.send(json!({ "t": "switched", "path": self.path }));
                    continue 'file;
                }
                if !self.tick(&mut beat) {
                    return;
                }
                let Ok(len) = fs::metadata(&self.path).map(|m| m.len()) else {
                    continue;
                };
                if len < offset {
                    // Cut short or rewritten: read it again from scratch.
                    continue 'file;
                }
                if len == offset {
                    continue;
                }
                let Ok(bytes) = read_range(&self.path, offset, len) else {
                    continue;
                };
                pending.extend_from_slice(&bytes);
                offset = len;
                let Some(cut) = pending.iter().rposition(|b| *b == b'\n') else {
                    continue;
                };
                let complete: Vec<u8> = pending.drain(..=cut).collect();
                for line in String::from_utf8_lossy(&complete)
                    .split('\n')
                    .filter(|l| !l.is_empty())
                {
                    transcript.accept(line);
                }
                if let Some(from) = first_change(&shown, transcript.items()) {
                    shown = transcript.items().to_vec();
                    self.out.send(json!({ "t": "items", "from": from,
                                          "items": shown[from..].iter().map(Item::to_json).collect::<Vec<_>>() }));
                }
            }
        }
    }

    /// Waits one tick; false once whoever started this has gone.
    fn tick(&mut self, beat: &mut Instant) -> bool {
        thread::sleep(TICK);
        if self.gone.load(Ordering::SeqCst) {
            return false;
        }
        if beat.elapsed() >= HEARTBEAT {
            *beat = Instant::now();
            let mut err = std::io::stderr();
            if err.write_all(b".").and_then(|_| err.flush()).is_err() {
                return false;
            }
        }
        true
    }

    fn send_status(&mut self, said: &Said) {
        let status = match self.kind {
            "agy" => agy_status(said),
            _ => claude_status(said, &self.path),
        };
        let text = status.to_string();
        if self.out.last_status.as_deref() != Some(text.as_str()) {
            self.out.last_status = Some(text);
            let mut v = status;
            v["t"] = json!("status");
            self.out.send(v);
        }
    }
}

/// The transcript read from a line boundary far enough back for
/// `MIN_ITEMS` rows before `before` (the end of the file when `None`);
/// returns the reader, where it started, and where it stopped.
fn load(kind: &str, path: &Path, before: Option<u64>) -> (Box<dyn Transcript>, u64, u64) {
    let len = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let end = before.unwrap_or(len).min(len);
    let mut window = FIRST_WINDOW;
    let start = loop {
        let start = align(path, end.saturating_sub(window));
        if start == 0 || window >= MAX_WINDOW {
            break start;
        }
        let mut probe = reader(kind);
        feed(&mut *probe, path, start, end);
        if probe.items().len() >= MIN_ITEMS {
            break start;
        }
        window *= 2;
    };
    let mut transcript = reader(kind);
    let stopped = feed(&mut *transcript, path, start, len);
    (transcript, start, stopped)
}

/// Feeds the complete lines in `[from, to)`; returns where the last one ended.
fn feed(t: &mut dyn Transcript, path: &Path, from: u64, to: u64) -> u64 {
    let Ok(bytes) = read_range(path, from, to) else {
        return from;
    };
    let Some(cut) = bytes.iter().rposition(|b| *b == b'\n') else {
        return from;
    };
    for line in String::from_utf8_lossy(&bytes[..cut])
        .split('\n')
        .filter(|l| !l.is_empty())
    {
        t.accept(line);
    }
    from + cut as u64 + 1
}

/// The first line boundary at or after `at`.
fn align(path: &Path, at: u64) -> u64 {
    if at == 0 {
        return 0;
    }
    let Ok(mut f) = File::open(path) else {
        return 0;
    };
    if f.seek(SeekFrom::Start(at - 1)).is_err() {
        return at;
    }
    let mut buf = [0u8; 64 * 1024];
    let mut pos = at - 1;
    loop {
        match f.read(&mut buf) {
            Ok(0) | Err(_) => return pos,
            Ok(n) => {
                if let Some(i) = buf[..n].iter().position(|b| *b == b'\n') {
                    return pos + i as u64 + 1;
                }
                pos += n as u64;
            }
        }
    }
}

fn read_range(path: &Path, from: u64, to: u64) -> std::io::Result<Vec<u8>> {
    let mut f = File::open(path)?;
    f.seek(SeekFrom::Start(from))?;
    let mut bytes = Vec::with_capacity(to.saturating_sub(from) as usize);
    f.take(to.saturating_sub(from)).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// `claude-opus-5-5` as Claude Code itself names it, `Opus 5.5`.
pub fn display_model(id: &str) -> String {
    let parts: Vec<&str> = id.split('-').collect();
    match parts.as_slice() {
        ["claude", family @ ("opus" | "sonnet" | "haiku" | "fable"), major, minor, ..]
            if major.chars().all(|c| c.is_ascii_digit())
                && minor.chars().all(|c| c.is_ascii_digit()) =>
        {
            let mut f = family.chars();
            let cap = f
                .next()
                .map(|c| c.to_ascii_uppercase().to_string() + f.as_str())
                .unwrap_or_default();
            format!("{cap} {major}.{minor}")
        }
        _ => id.to_owned(),
    }
}

/// What Claude's header shows: the transcript for what moves with every
/// reply, and the session's status line snapshot (kept by `statusline`) for
/// what exists nowhere else, the window size, the limits, the cost, and
/// Claude's own word on the prompt cache.
fn claude_status(said: &Said, transcript: &Path) -> Value {
    let session = transcript
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let snapshot: Option<Value> = crate::fsutil::safe_id(session)
        .then(|| {
            fs::read(
                paths::state_dir()
                    .join("claude")
                    .join(session)
                    .join("status.json"),
            )
            .ok()
        })
        .flatten()
        .and_then(|b| serde_json::from_slice(&b).ok());
    let snap = |p: &str| {
        snapshot
            .as_ref()
            .and_then(|s| s.pointer(p))
            .filter(|v| !v.is_null())
            .cloned()
    };
    let model_id = said
        .model
        .clone()
        .or_else(|| snap("/model/id").and_then(|v| v.as_str().map(str::to_owned)));
    let window = snap("/context_window/context_window_size")
        .and_then(|v| v.as_u64())
        .or_else(|| {
            model_id
                .as_deref()
                .and_then(crate::statusline::known_window)
        });
    let tokens = said.context_tokens;
    let percent = match (tokens, window) {
        (Some(t), Some(w)) if w > 0 => {
            Some(((t as f64 * 100.0 / w as f64).round() as u64).min(100))
        }
        _ => snap("/context_window/used_percentage")
            .and_then(|v| v.as_f64())
            .map(|p| p.round() as u64),
    };
    let (cache_warm, cache_expires_at) =
        match (snap("/prompt_cache/warm"), snap("/prompt_cache/expires_at")) {
            (Some(w), e) => (w.as_bool(), e.and_then(|e| e.as_u64())),
            _ => match (
                said.last_request_at,
                said.cache_ttl.or(said.last_request_at.map(|_| 300)),
            ) {
                (Some(at), Some(ttl)) => (Some(true), Some(at + ttl)),
                _ => (None, None),
            },
        };
    let mut limits = Vec::new();
    for (key, label) in [("five_hour", "5-hour"), ("seven_day", "7-day")] {
        if let Some(used) =
            snap(&format!("/rate_limits/{key}/used_percentage")).and_then(|v| v.as_f64())
        {
            limits.push(json!({ "label": label, "used_percent": used.round() as i64,
                                "resets_at": snap(&format!("/rate_limits/{key}/resets_at")) }));
        }
    }
    json!({
        "source": "claude",
        "model": snap("/model/display_name").or_else(|| model_id.as_deref().map(|m| json!(display_model(m)))),
        "model_id": model_id,
        "effort": said.effort.clone().map(Value::from).or_else(|| snap("/effort/level")),
        "context_tokens": tokens,
        "context_window": window,
        "context_percent": percent,
        "cost_usd": snap("/cost/total_cost_usd"),
        "lines_added": snap("/cost/total_lines_added"),
        "lines_removed": snap("/cost/total_lines_removed"),
        "thinking": snap("/thinking/enabled"),
        "fast_mode": snap("/fast_mode"),
        "cache_warm": cache_warm,
        "cache_expires_at": cache_expires_at,
        "limits": limits,
        "version": said.version.clone().map(Value::from).or_else(|| snap("/version")),
    })
}

/// agy writes no model into its transcript; its settings have it, with the
/// effort in brackets (`Gemini 4 Argon (Medium)`).
fn agy_status(said: &Said) -> Value {
    let model = agy_model();
    let effort = model.as_deref().and_then(|m| {
        let open = m.rfind('(')?;
        m[open + 1..].strip_suffix(')').map(str::to_lowercase)
    });
    json!({
        "source": "agy",
        "model": model,
        "effort": effort,
        "context_tokens": said.context_tokens,
        "limits": [],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_ids_read_as_claude_names_them() {
        assert_eq!(display_model("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(display_model("claude-sonnet-5-5-20261001"), "Sonnet 5.5");
        assert_eq!(display_model("gpt-9"), "gpt-9");
    }

    #[test]
    fn a_window_starts_on_a_line() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("t.jsonl");
        fs::write(&p, "aaaa\nbbbb\ncccc\n").unwrap();
        assert_eq!(align(&p, 0), 0);
        assert_eq!(align(&p, 5), 5);
        assert_eq!(align(&p, 6), 10);
        assert_eq!(align(&p, 15), 15);
    }
}
