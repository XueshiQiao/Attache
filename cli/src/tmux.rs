//! Every tmux command this program runs goes through here.
//!
//! tmux finds its server by user id, not by `HOME`, so a test that only
//! points `HOME` somewhere else still talks to the owner's real server, the
//! one with long-running agents in it. `ATTACHE_TMUX` names another binary
//! (a test's recorder), and `ATTACHE_TMUX_SOCKET` adds `-L <name>` for an
//! isolated server; nothing in this crate calls `tmux` any other way.

use std::env;
use std::process::{Command, Output, Stdio};

pub fn command() -> Command {
    let bin = env::var("ATTACHE_TMUX")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "tmux".into());
    let mut c = Command::new(bin);
    if let Some(socket) = env::var("ATTACHE_TMUX_SOCKET")
        .ok()
        .filter(|s| !s.is_empty())
    {
        c.arg("-L").arg(socket);
    }
    c.stdin(Stdio::null());
    c
}

/// Runs one tmux command; its output when it succeeded.
pub fn run(args: &[&str]) -> Option<Output> {
    let out = command().args(args).stderr(Stdio::null()).output().ok()?;
    out.status.success().then_some(out)
}

/// Runs one tmux command and returns its stdout lines.
pub fn lines(args: &[&str]) -> Vec<String> {
    run(args)
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}
