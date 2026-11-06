//! Where things live on the host.

use std::env;
use std::path::PathBuf;

pub fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Claude Code's own folder: `CLAUDE_CONFIG_DIR` when set, as Claude Code
/// itself reads it, else `~/.claude`.
pub fn claude_dir() -> PathBuf {
    match env::var_os("CLAUDE_CONFIG_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => home().join(".claude"),
    }
}

/// What `attache-cli` writes for itself: `$XDG_STATE_HOME/attache`, else
/// `~/.local/state/attache`.
pub fn state_dir() -> PathBuf {
    match env::var_os("XDG_STATE_HOME") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("attache"),
        _ => home().join(".local/state/attache"),
    }
}

/// The folder the phone's file inbox reads its queue from. It predates this
/// program (`attache-send`), so it keeps its place.
pub fn share_dir() -> PathBuf {
    home().join(".local/share/attache")
}
