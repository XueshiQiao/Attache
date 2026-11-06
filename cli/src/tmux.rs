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
        .unwrap_or_else(binary);
    let mut c = Command::new(bin);
    // Without a UTF-8 locale tmux rewrites every byte it thinks unprintable
    // as `_`: the `\x01` field separators and every Chinese character in a
    // screen. An SSH command often has no locale at all; `-u` makes tmux
    // assume UTF-8 whatever the environment says (measured on 3.6a under
    // `env -i`: `%0_18852` without, `%0\x0118852` with).
    c.arg("-u");
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

/// Where tmux is. An SSH command runs with the system's bare PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin` on macOS), which holds no Homebrew, so
/// `tmux` alone was not found and every list came back empty: the phone's
/// agent list, read over an exec channel since protocol 2, showed nothing
/// (seen 2026-11-06). Reached through tmux's own `run-shell` it had worked,
/// because that runs with the server's PATH. The usual places are tried
/// after PATH.
fn binary() -> String {
    let on_path = env::var_os("PATH")
        .map(|p| env::split_paths(&p).any(|d| d.join("tmux").is_file()))
        .unwrap_or(false);
    if on_path {
        return "tmux".into();
    }
    [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/home/linuxbrew/.linuxbrew/bin/tmux",
        "/usr/bin/tmux",
        "/bin/tmux",
    ]
    .iter()
    .find(|p| std::path::Path::new(p).is_file())
    .map(|p| p.to_string())
    .unwrap_or_else(|| "tmux".into())
}
