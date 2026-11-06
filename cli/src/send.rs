//! `attache-cli send <file>...`: hands files to the phone's inbox.
//!
//! What `attache-send`, the shell script it replaces, did, byte for byte,
//! because the phone already reads it that way: each absolute path appended
//! as a line to `~/.local/share/attache/outbox.queue` (the phone renames the
//! file away and reads it, so an append never lands in a half-read queue),
//! then the global option `@attache_push` set to `<epoch>-<pid>:<last path>`,
//! then every session's current window renamed to its own name, which is
//! what reaches a control client as a notification and makes the phone look.

use crate::{paths, tmux};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn run(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Usage: attache-cli send <file-path> [more-files...]");
        return 1;
    }
    let mut queued = Vec::new();
    for arg in args {
        let path = Path::new(arg);
        let abs = match path.canonicalize() {
            Ok(p) if p.is_file() => p,
            _ => {
                eprintln!("attache-cli send: file not found: {arg}");
                return 1;
            }
        };
        // A path with a newline in it would read as two entries.
        let Some(text) = abs.to_str().filter(|s| !s.contains('\n')) else {
            eprintln!("attache-cli send: unsupported file name: {arg}");
            return 1;
        };
        queued.push(text.to_owned());
    }
    let dir = paths::share_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("attache-cli send: {e}");
        return 1;
    }
    let queue = dir.join("outbox.queue");
    for p in &queued {
        // One write per line, opened for appending: lines from two senders
        // at once stay whole.
        let wrote = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&queue)
            .and_then(|mut f| f.write_all(format!("{p}\n").as_bytes()));
        if let Err(e) = wrote {
            eprintln!("attache-cli send: {e}");
            return 1;
        }
        println!("Queued for Attaché mobile inbox: {p}");
    }
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let token = format!("{epoch}-{}:{}", std::process::id(), queued.last().unwrap());
    tmux::run(&["set", "-g", "@attache_push", &token]);
    for session in tmux::lines(&["list-sessions", "-F", "#{session_id}"]) {
        let name = tmux::lines(&["display-message", "-p", "-t", &session, "#{window_name}"]);
        if let Some(name) = name.first() {
            tmux::run(&["rename-window", "-t", &session, name]);
        }
    }
    0
}
