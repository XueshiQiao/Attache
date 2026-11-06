//! `attache-cli input <pane> --text <base64> [--enter]` and
//! `attache-cli input <pane> --key <name>`: typing into an agent.
//!
//! The text comes base64-encoded: it arrives on an SSH command line, and
//! base64 has no character any shell or tmux would act on.
//!
//! A message is several tmux commands (leave copy mode, put the text in,
//! press Enter), and the phone and the tablet can send to the same pane at
//! once; two interleaved would arrive as one garbled line. So each message
//! holds the pane's lock from its first command to its last. Other panes
//! are not held up.

use crate::fsutil::Lock;
use crate::{paths, tmux};
use std::thread;
use std::time::Duration;

/// Keys a client may press on its own: the ones a panel or an approval
/// takes. Anything else is typed as text.
const KEYS: [&str; 16] = [
    "Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BSpace", "1", "2", "3", "4", "5",
    "6", "7", "8",
];

pub fn run(args: &[String]) -> i32 {
    let Some(pane) = args.first().filter(|p| {
        p.starts_with('%') && p.len() > 1 && p[1..].chars().all(|c| c.is_ascii_digit())
    }) else {
        return usage();
    };
    let rest = &args[1..];
    let lock_path = paths::state_dir()
        .join("input")
        .join(format!("{}.lock", &pane[1..]));
    let Ok(Some(_lock)) = Lock::acquire(&lock_path, Duration::from_secs(10)) else {
        eprintln!("attache-cli input: the pane is busy");
        return 1;
    };
    match rest {
        [flag, key] if flag == "--key" => {
            if !KEYS.contains(&key.as_str()) {
                return usage();
            }
            if tmux::run(&["send-keys", "-t", pane, key]).is_some() {
                0
            } else {
                1
            }
        }
        [flag, b64, more @ ..] if flag == "--text" && (more.is_empty() || more == ["--enter"]) => {
            let Some(text) = decode(b64).and_then(|b| String::from_utf8(b).ok()) else {
                return usage();
            };
            if type_text(pane, &text, !more.is_empty()) {
                0
            } else {
                1
            }
        }
        _ => usage(),
    }
}

fn usage() -> i32 {
    eprintln!("Usage: attache-cli input <%pane> --text <base64> [--enter] | --key <name>");
    2
}

fn type_text(pane: &str, text: &str, enter: bool) -> bool {
    // A pane scrolled back in copy mode would take the text as copy-mode
    // keys.
    let in_mode = tmux::lines(&["display-message", "-p", "-t", pane, "#{pane_in_mode}"]);
    if in_mode.first().map(String::as_str) == Some("1") {
        tmux::run(&["send-keys", "-X", "-t", pane, "cancel"]);
    }
    let sent = if text.starts_with('/') || text.starts_with('!') {
        // Typed, not pasted: `/` and `!` mean something to Claude Code only
        // as the first key typed on an empty prompt.
        tmux::run(&["send-keys", "-t", pane, "-l", "--", text]).is_some()
    } else {
        // A bracketed paste: the text arrives as one piece, and nothing in it
        // is read as a key binding.
        let buffer = format!("attache-input-{}", std::process::id());
        tmux::run(&["set-buffer", "-b", &buffer, "--", text]).is_some()
            && tmux::run(&["paste-buffer", "-d", "-p", "-b", &buffer, "-t", pane]).is_some()
    };
    if !sent {
        return false;
    }
    if enter {
        // The agent's prompt takes a moment to finish taking a paste; an
        // Enter inside it is a newline in the message, not a send.
        thread::sleep(Duration::from_millis(150));
        return tmux::run(&["send-keys", "-t", pane, "Enter"]).is_some();
    }
    true
}

/// Standard base64, padding optional.
pub fn decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.trim_end_matches('=').bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_reads_back() {
        assert_eq!(decode("5L2g5aW9IHdvcmxk").unwrap(), "你好 world".as_bytes());
        assert_eq!(decode("YQ==").unwrap(), b"a");
        assert_eq!(decode("YWI").unwrap(), b"ab");
        assert_eq!(decode("").unwrap(), b"");
        assert!(decode("a b").is_none());
    }
}
