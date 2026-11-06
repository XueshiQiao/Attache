//! Where things live on the host.

use std::env;
use std::path::PathBuf;

#[cfg(test)]
thread_local! {
    /// A test's own home folder. Tests run as threads of one process, so
    /// they cannot each set `HOME`; with this set, the environment's
    /// `CLAUDE_CONFIG_DIR` and `XDG_STATE_HOME` are ignored too.
    pub static TEST_HOME: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn test_home() -> Option<PathBuf> {
    TEST_HOME.with(|h| h.borrow().clone())
}

#[cfg(not(test))]
fn test_home() -> Option<PathBuf> {
    None
}

pub fn home() -> PathBuf {
    if let Some(home) = test_home() {
        return home;
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Claude Code's own folder: `CLAUDE_CONFIG_DIR` when set, as Claude Code
/// itself reads it, else `~/.claude`.
pub fn claude_dir() -> PathBuf {
    if test_home().is_some() {
        return home().join(".claude");
    }
    match env::var_os("CLAUDE_CONFIG_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => home().join(".claude"),
    }
}

/// What `attache-cli` writes for itself: `$XDG_STATE_HOME/attache`, else
/// `~/.local/state/attache`.
pub fn state_dir() -> PathBuf {
    if test_home().is_some() {
        return home().join(".local/state/attache");
    }
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
