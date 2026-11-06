//! `attache-cli input <pane> --text <base64> [--enter]` and
//! `attache-cli input <pane> --key <name> --if <condition>`: typing into an
//! agent.
//!
//! The text comes base64-encoded: it arrives on an SSH command line, and
//! base64 has no character any shell or tmux would act on.
//!
//! A message is several tmux commands (leave copy mode, put the text in,
//! press Enter), and the phone and the tablet can send to the same pane at
//! once; two interleaved would arrive as one garbled line. So each message
//! holds the pane's lock from its first command to its last. Other panes
//! are not held up.
//!
//! **Nothing is pressed on the strength of what a client saw.** A client
//! reads the screen, the person taps, and by the time the key arrives the
//! screen can be another one: over the owner's relayed 5G link that gap is
//! most of a second. A key that lands somewhere it was not meant for can
//! cost the session its prompt cache, which no client can undo: an Esc on
//! Claude's idle prompt is half of the two that open its rewind menu, a Tab
//! there turns thinking on or off, and a message pasted into an open picker
//! ends with an Enter that chooses something. So each key names the screen
//! it is for (`--if`), and a message needs Claude's own input box; both are
//! read again here, holding the pane, right before anything is sent. What
//! is left is the few milliseconds between that capture and the key.
//!
//! What happened is printed as one JSON line, `{"sent":true}` or
//! `{"sent":false,"why":…}`, because a client reading through `run-shell`
//! sees stdout and not the exit status.

use crate::agents::{agy_state, discover, State};
use crate::fsutil::Lock;
use crate::host::RealHost;
use crate::screen::{self, Reading};
use crate::{paths, tmux};
use serde_json::json;
use std::thread;
use std::time::Duration;

/// The keys an approval takes: the option's number, never an Enter after it
/// (Claude selects on the digit; an Enter would submit the input box).
const APPROVAL_KEYS: [&str; 8] = ["1", "2", "3", "4", "5", "6", "7", "8"];
/// The keys a panel takes. Never letters: what one does depends on the panel.
const PANEL_KEYS: [&str; 7] = ["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab"];

enum Condition {
    /// The permission menu with this fingerprint is on screen.
    Approval(String),
    /// A panel or picker is open over the input box; with a fingerprint,
    /// that very panel. Enter, the key that chooses, needs the fingerprint.
    Panel(Option<String>),
    /// A turn is visibly running (Claude's `✻ Verb…` line).
    Working,
}

pub fn run(args: &[String]) -> i32 {
    let Some(pane) = args.first().filter(|p| screen::is_pane(p)) else {
        return usage();
    };
    let rest = &args[1..];
    enum Ask {
        Key(String, Condition),
        Text(String, bool),
        Choose(u32, String),
    }
    let ask = match rest {
        [flag, n, when, cond] if flag == "--choose" && when == "--if" => {
            // `submit`: a multiple choice's Submit row, which ends that
            // question and moves on to the next.
            let n = if n == "submit" { Ok(0) } else { n.parse::<u32>().and_then(|n| if n == 0 { "x".parse() } else { Ok(n) }) };
            let (Ok(n), Some(fp)) = (n, cond.strip_prefix("question:")) else {
                return usage();
            };
            if fp.len() != 16 || !fp.chars().all(|c| c.is_ascii_hexdigit()) {
                return usage();
            }
            Ask::Choose(n, fp.to_owned())
        }
        [flag, key, when, cond] if flag == "--key" && when == "--if" => {
            let Some(c) = condition(cond) else {
                return usage();
            };
            let allowed = match c {
                Condition::Approval(_) => APPROVAL_KEYS.contains(&key.as_str()),
                Condition::Panel(ref fp) => {
                    PANEL_KEYS.contains(&key.as_str()) && (key != "Enter" || fp.is_some())
                }
                Condition::Working => key == "Escape",
            };
            if !allowed {
                return usage();
            }
            Ask::Key(key.clone(), c)
        }
        [flag, b64, more @ ..] if flag == "--text" && (more.is_empty() || more == ["--enter"]) => {
            let Some(text) = decode(b64).and_then(|b| String::from_utf8(b).ok()) else {
                return usage();
            };
            Ask::Text(text, !more.is_empty())
        }
        _ => return usage(),
    };
    let lock_path = paths::state_dir()
        .join("input")
        .join(format!("{}.lock", &pane[1..]));
    let Ok(Some(_lock)) = Lock::acquire(&lock_path, Duration::from_secs(10)) else {
        return answer(Err("busy"));
    };
    let agent = discover(&RealHost, Some(pane)).into_iter().next();
    let kind = agent.as_ref().map(|a| a.kind);
    match ask {
        Ask::Key(key, cond) => {
            // Every condition is about Claude's screen; on any other agent
            // there is nothing to check it against, so nothing is pressed.
            let Some(agent) = agent.filter(|a| a.kind == "claude") else {
                return answer(Err("not_claude"));
            };
            // A pane scrolled back in copy mode would take the key as a
            // copy-mode key, and Claude would get nothing while this said
            // it was sent. The screen below the mode is what is read, so
            // leaving the mode first changes nothing the check sees.
            leave_copy_mode(pane);
            let read = Reading::from_lines(&screen::capture(pane));
            if let Err(why) = key_allowed(&read, &key, &cond) {
                return answer(Err(why));
            }
            // The working line alone is drawn text, and a list item in the
            // agent's own output can look like it; Claude's own session file
            // has to say it is busy as well.
            if matches!(cond, Condition::Working) && agent.state != State::Working {
                return answer(Err("not_working"));
            }
            answer(
                tmux::run(&["send-keys", "-t", pane, &key])
                    .map(|_| ())
                    .ok_or("tmux"),
            )
        }
        Ask::Choose(n, fp) => {
            if kind != Some("claude") {
                return answer(Err("not_claude"));
            }
            leave_copy_mode(pane);
            answer(choose(pane, n, &fp))
        }
        Ask::Text(text, enter) => {
            let ready = match kind {
                Some("claude") => text_allowed(&Reading::from_lines(&screen::capture(pane))),
                Some("agy") => {
                    if agy_state(&tmux::lines(&["capture-pane", "-p", "-J", "-t", pane])) == State::NeedsYou {
                        Err("question")
                    } else {
                        Ok(())
                    }
                }
                // An agent recognised by name only: no reader for its
                // screen yet, so typed as the person asked.
                Some(_) => Ok(()),
                // No agent at all in the pane: nothing a chat sends to.
                None => Err("no_agent"),
            };
            if let Err(why) = ready {
                return answer(Err(why));
            }
            let claude = kind == Some("claude");
            answer(type_text(pane, &text, enter, claude))
        }
    }
}

fn condition(s: &str) -> Option<Condition> {
    let fingerprint = |fp: &str| {
        (fp.len() == 16 && fp.chars().all(|c| c.is_ascii_hexdigit())).then(|| fp.to_owned())
    };
    match s {
        "panel" => Some(Condition::Panel(None)),
        "working" => Some(Condition::Working),
        _ => {
            if let Some(fp) = s.strip_prefix("panel:") {
                return fingerprint(fp).map(|f| Condition::Panel(Some(f)));
            }
            fingerprint(s.strip_prefix("approval:")?).map(Condition::Approval)
        }
    }
}

/// Whether `key` may be pressed on this screen for this condition.
fn key_allowed(read: &Reading, key: &str, cond: &Condition) -> Result<(), &'static str> {
    match cond {
        Condition::Approval(fp) => {
            let a = read.approval.as_ref().ok_or("question_gone")?;
            if &a.fingerprint != fp {
                return Err("question_changed");
            }
            let n: usize = key.parse().map_err(|_| "no_such_option")?;
            if n == 0 || n > a.options.len() {
                return Err("no_such_option");
            }
            Ok(())
        }
        Condition::Panel(fp) => {
            read.panel.as_ref().ok_or("panel_closed")?;
            match fp {
                Some(fp) if read.panel_fingerprint.as_ref() != Some(fp) => Err("panel_changed"),
                _ => Ok(()),
            }
        }
        Condition::Working => {
            // Only while the turn is visibly running and nothing is asking:
            // an Esc after the turn ended reaches the idle prompt.
            if read.approval.is_some() || read.panel.is_some() {
                return Err("not_working");
            }
            read.activity.as_ref().map(|_| ()).ok_or("not_working")
        }
    }
}

/// A message goes only into Claude's own input box: not into a permission
/// menu, where letters are answers, and not into a panel, where its Enter
/// would choose whatever is selected.
fn text_allowed(read: &Reading) -> Result<(), &'static str> {
    if read.approval.is_some() {
        return Err("question");
    }
    if read.panel.is_some() {
        return Err("panel");
    }
    if !read.prompt {
        return Err("no_prompt");
    }
    Ok(())
}

fn answer(r: Result<(), &'static str>) -> i32 {
    match r {
        Ok(()) => {
            println!("{}", json!({ "sent": true }));
            0
        }
        Err(why) => {
            println!("{}", json!({ "sent": false, "why": why }));
            // 1 for what went wrong, 3 for what was refused on purpose,
            // `enter_withheld` included: the text went in, and the Enter
            // after it was held back because the screen changed.
            if why == "tmux" || why == "busy" {
                1
            } else {
                3
            }
        }
    }
}

fn usage() -> i32 {
    eprintln!(
        "Usage: attache-cli input <%pane> --text <base64> [--enter]\n       attache-cli input <%pane> --key <name> --if approval:<fingerprint>|panel[:<fingerprint>]|working\n       attache-cli input <%pane> --choose <n|submit> --if question:<fingerprint>"
    );
    2
}

/// Picks answer `n` of the question on screen: the cursor is moved there
/// with arrows, the screen read again to see it arrived on that very
/// question, and only then Enter. Arrows move nothing but the cursor inside
/// the form; the Enter, the key that commits, waits for the second look.
fn choose(pane: &str, n: u32, fp: &str) -> Result<(), &'static str> {
    let read = |pane: &str| screen::question(&screen::capture(pane));
    let q = read(pane).ok_or("question_gone")?;
    if q.fingerprint != fp {
        return Err("question_changed");
    }
    if n == 0 && !q.submit_row {
        return Err("no_such_option");
    }
    if n > 0 {
        let option = q.options.iter().find(|o| o.number == n).ok_or("no_such_option")?;
        if option.typed {
            return Err("typed_answer");
        }
    }
    // Rows in the order the cursor moves through them: in a multiple choice
    // the Submit row sits between the typed answer and "Chat about this".
    let (from, to) = q.positions(n).ok_or("no_such_option")?;
    let (key, steps) = if to >= from { ("Down", (to - from) as u32) } else { ("Up", (from - to) as u32) };
    if steps > 0 {
        let mut args = vec!["send-keys", "-t", pane];
        args.extend(std::iter::repeat_n(key, steps as usize));
        tmux::run(&args).ok_or("tmux")?;
        thread::sleep(Duration::from_millis(150));
    }
    let now = read(pane).ok_or("question_gone")?;
    if now.fingerprint != fp || now.cursor != n {
        return Err("question_changed");
    }
    tmux::run(&["send-keys", "-t", pane, "Enter"]).map(|_| ()).ok_or("tmux")
}

fn leave_copy_mode(pane: &str) {
    let in_mode = tmux::lines(&["display-message", "-p", "-t", pane, "#{pane_in_mode}"]);
    if in_mode.first().map(String::as_str) == Some("1") {
        tmux::run(&["send-keys", "-X", "-t", pane, "cancel"]);
    }
}

fn type_text(pane: &str, text: &str, enter: bool, claude: bool) -> Result<(), &'static str> {
    // A pane scrolled back in copy mode would take the text as copy-mode
    // keys.
    leave_copy_mode(pane);
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
        return Err("tmux");
    }
    if !enter {
        return Ok(());
    }
    // The agent's prompt takes a moment to finish taking a paste; an Enter
    // inside it is a newline in the message, not a send.
    thread::sleep(Duration::from_millis(150));
    // Read again before the Enter: a permission menu or a picker that came
    // up in those moments would take it as choosing whatever is selected.
    // The text stays in the box, unsent, for the person to send again.
    if claude {
        let read = Reading::from_lines(&screen::capture(pane));
        if read.approval.is_some() || read.panel.is_some() || !read.prompt {
            return Err("enter_withheld");
        }
    }
    tmux::run(&["send-keys", "-t", pane, "Enter"])
        .map(|_| ())
        .ok_or("tmux")
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
