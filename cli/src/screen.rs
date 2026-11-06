//! `attache-cli screen <%pane>`: what Claude Code has on screen that a
//! client may act on, read from `capture-pane`.
//!
//! ```text
//! {"pane","kind","prompt":<bool>,"approval":{…}|null,"panel":[…]|null,"activity":{…}|null}
//! ```
//!
//! These readers decide which keys reach an agent, and a key in the wrong
//! place is the one mistake a client cannot take back: an Esc that lands on
//! Claude's idle prompt is half of the two that open its rewind menu, a Tab
//! there turns thinking on or off, and either can cost the session its
//! prompt cache. So they are deliberately narrow (a miss costs a trip to the
//! terminal), they live here once rather than in every client, and `input`
//! runs them again itself, holding the pane, immediately before it presses
//! anything: what a client was shown is a request, not a permission.
//!
//! Ported from the phone's `ApprovalPrompts`, `ScreenPanels` and
//! `AgentActivities` (AttacheAndroid, 2026-11-05/06), which were read from
//! real captures of Claude Code 2.1.x. Only Claude's screen is read: the
//! layouts are Claude's, and on any other agent every reading is null.

use crate::agents::{discover, Agent};
use crate::host::RealHost;
use crate::tmux;
use serde_json::{json, Value};

/// Rows of history above the visible screen read with it: an approval's
/// subject can start above the top of a short pane.
const HISTORY: &str = "-40";

pub fn run(args: &[String]) -> i32 {
    let [pane] = args else {
        return usage();
    };
    if !is_pane(pane) {
        return usage();
    }
    let Some(agent) = discover(&RealHost, Some(pane)).into_iter().next() else {
        println!("{}", json!({ "pane": pane, "kind": null }));
        return 0;
    };
    let read = Reading::of(&agent);
    println!("{}", read.to_json(&agent));
    0
}

fn usage() -> i32 {
    eprintln!("Usage: attache-cli screen <%pane>");
    2
}

pub fn is_pane(p: &str) -> bool {
    p.starts_with('%') && p.len() > 1 && p[1..].chars().all(|c| c.is_ascii_digit())
}

/// The pane's screen, as the readers here want it.
pub fn capture(pane: &str) -> Vec<String> {
    tmux::lines(&["capture-pane", "-p", "-J", "-t", pane, "-S", HISTORY])
}

/// Everything read off one capture of one Claude pane.
pub struct Reading {
    pub prompt: bool,
    pub approval: Option<Approval>,
    pub panel: Option<Vec<String>>,
    /// A hash of `panel`: an Enter, the key that chooses, is pressed only
    /// on the very panel the person was shown.
    pub panel_fingerprint: Option<String>,
    /// A question Claude asked with `AskUserQuestion`, as a menu to pick from.
    pub question: Option<Question>,
    pub activity: Option<Activity>,
}

impl Reading {
    pub fn of(agent: &Agent) -> Reading {
        if agent.kind != "claude" {
            return Reading::nothing();
        }
        Reading::from_lines(&capture(&agent.pane.id))
    }

    pub fn nothing() -> Reading {
        Reading {
            prompt: false,
            approval: None,
            panel: None,
            panel_fingerprint: None,
            question: None,
            activity: None,
        }
    }

    pub fn from_lines(rows: &[String]) -> Reading {
        let approval = approval(rows);
        let question = if approval.is_some() { None } else { question(rows) };
        // A menu has no input box either; it is the menu, not a panel.
        let panel = if approval.is_some() || question.is_some() { None } else { panel(rows) };
        Reading {
            prompt: input_box(&trimmed(rows)).is_some(),
            panel_fingerprint: panel.as_ref().map(|p| fnv(&p.join("\n"))),
            panel,
            question,
            activity: activity(rows),
            approval,
        }
    }

    pub fn to_json(&self, agent: &Agent) -> Value {
        json!({
            "pane": agent.pane.id,
            "kind": agent.kind,
            "prompt": self.prompt,
            "approval": self.approval.as_ref().map(Approval::to_json),
            "panel": self.panel,
            "panel_fingerprint": self.panel_fingerprint,
            "question": self.question.as_ref().map(Question::to_json),
            "activity": self.activity.as_ref().map(|a| json!({ "verb": a.verb, "detail": a.detail })),
        })
    }
}

fn trimmed(rows: &[String]) -> Vec<&str> {
    let mut lines: Vec<&str> = rows.iter().map(|r| r.trim_end()).collect();
    while lines.last().is_some_and(|l| l.trim().is_empty()) {
        lines.pop();
    }
    lines
}

/// A run of `─` from the left edge, with anything after it: a named session
/// writes its name into the rule above the box (`──── Herdr 手机端 ─`), and a
/// rule that had to be all `─` missed that box and called the bare prompt a
/// panel.
fn is_box_rule(line: &str) -> bool {
    line.trim().chars().take_while(|&c| c == '─').count() >= 20
}

/// Claude's input box, as the indices of its two rules: a `❯` line between
/// two rules, the lower one near the bottom.
///
/// The upper rule may be anywhere above: a draft of many lines pushes it
/// up the screen, and a box looked for only in the bottom rows was missed
/// under a long draft, which made the screen read as a panel and let its
/// keys through (found by review, 2026-11-06). Only the nearest rule above
/// the lower one is its top: a draft holds no rules.
fn input_box(lines: &[&str]) -> Option<(usize, usize)> {
    const BOTTOM_SEARCH: usize = 14;
    let from = lines.len().saturating_sub(BOTTOM_SEARCH);
    let rules: Vec<usize> = (0..lines.len()).filter(|&i| is_box_rule(lines[i])).collect();
    rules.windows(2).rev().find_map(|pair| {
        let (top, bottom) = (pair[0], pair[1]);
        (bottom >= from && (top + 1..bottom).any(|i| lines[i].trim_start().starts_with('❯')))
            .then_some((top, bottom))
    })
}

// ---------------------------------------------------------------- panel

/// A panel or picker over the input box, the way `/usage`, `/model`,
/// `/resume` and `/effort` open one: the input box is not drawn, or the
/// bottom of the screen names the keys a dialog takes. Measured with
/// `/usage` on Claude Code 2.1, 2026-11-05: the panel took the whole screen
/// and the input box came back only after Esc. Hands back the last rows.
pub fn panel(rows: &[String]) -> Option<Vec<String>> {
    const SHOWN: usize = 40;
    let mut lines = trimmed(rows);
    while lines.first().is_some_and(|l| l.trim().is_empty()) {
        lines.remove(0);
    }
    if lines.is_empty() {
        return None;
    }
    let names_dialog_keys = |rows: &[&str]| {
        let footer = rows[rows.len().saturating_sub(3)..].join(" ").to_lowercase();
        (footer.contains("esc to") && !footer.contains("esc to interrupt")) || footer.contains("enter to")
    };
    // With the box drawn, only what is below it can name a dialog's keys
    // (a picker opened under it): the person's own draft, inside the box,
    // can say "press enter to confirm" too.
    if let Some((_, bottom)) = input_box(&lines) {
        if !names_dialog_keys(&lines[bottom + 1..]) {
            return None;
        }
    }
    Some(
        lines[lines.len().saturating_sub(SHOWN)..]
            .iter()
            .map(|l| l.to_string())
            .collect(),
    )
}

// ---------------------------------------------------------------- activity

/// Claude Code's live status line: `✻ Jitterbugging… (13s · ↓ 649 tokens)`.
#[derive(Debug, PartialEq)]
pub struct Activity {
    pub verb: String,
    pub detail: Option<String>,
}

/// The status line Claude draws while a turn runs. It sits a few rows above
/// the input box, with only Claude's tips between, and is looked for there
/// and nowhere else: an agent's own output can hold a bullet that ends in an
/// ellipsis.
///
/// ```text
/// ✻ Jitterbugging… (13s · ↓ 649 tokens · thought for 7s)
///   ⎿  Tip: Run Claude Code locally or remotely using the Claude desktop app
///
/// ────────────────────────────────
/// ❯
/// ────────────────────────────────
/// ```
pub fn activity(rows: &[String]) -> Option<Activity> {
    const SEARCH_ROWS: usize = 8;
    let lines: Vec<&str> = rows.iter().map(|r| r.trim_end()).collect();
    let rules: Vec<usize> = (0..lines.len()).filter(|&i| is_box_rule(lines[i])).collect();
    // The box's top rule is where to look up from; with one rule, that one.
    let box_top = match rules.len() {
        0 => return None,
        1 => rules[0],
        n => rules[n - 2],
    };
    (box_top.saturating_sub(SEARCH_ROWS)..box_top)
        .rev()
        .find_map(|i| activity_line(lines[i]))
}

fn activity_line(line: &str) -> Option<Activity> {
    // The glyphs Claude cycles through for its spinner.
    const SPINNER: &[char] = &['*', '·', '✢', '✳', '✶', '✻', '✽'];
    let rest = line.trim_start();
    let glyph = rest.chars().next()?;
    if !SPINNER.contains(&glyph) {
        return None;
    }
    let after = &rest[glyph.len_utf8()..];
    // At least one space between the glyph and the word.
    if !after.starts_with(char::is_whitespace) {
        return None;
    }
    let after = after.trim_start();
    let (word, brackets) = match after.find('(') {
        Some(open) => {
            let inner = after[open + 1..].trim_end().strip_suffix(')')?;
            (&after[..open], Some(inner))
        }
        None => (after, None),
    };
    let verb = word.trim();
    if verb.is_empty() || !verb.ends_with('…') {
        return None;
    }
    let detail = brackets
        .map(|b| {
            b.split('·')
                .map(str::trim)
                .filter(|p| !p.is_empty() && !p.starts_with("esc to"))
                .collect::<Vec<_>>()
                .join(" · ")
        })
        .filter(|d| !d.is_empty());
    Some(Activity {
        verb: verb.to_owned(),
        detail,
    })
}

// ---------------------------------------------------------------- question

/// A question Claude asked with `AskUserQuestion`: one question, one answer
/// picked from a list. Read from a real capture of Claude Code 2.1
/// (2026-11-06):
///
/// ```text
/// ────────────────────────────────
///  ☐ 提交钩子
///
/// │ 提交 release.yml 时，pre-commit 钩子……你想怎么处理？
///
/// ❯ 1. 这次跳过钩子 (Recommended)
///      用 git commit --no-verify 提交并推送 release.yml……
///   2. 允许 esbuild 运行安装脚本
///      在仓库根目录新建 pnpm-workspace.yaml……
///   3. 先不提交
///      release.yml 的改动先留在暂存区……
///   4. Type something.
/// ────────────────────────────────
///   5. Chat about this
///
/// Enter to select · ↑/↓ to navigate · Esc to cancel
/// ```
///
/// Narrow on purpose, as the permission menu is: several questions at once
/// (a row of tabs with Submit) and multiple choice (checkboxes) are left to
/// the terminal, and so are the two answers that need typing.
#[derive(Debug)]
pub struct Question {
    pub header: String,
    pub text: String,
    pub options: Vec<QuestionOption>,
    /// The option the cursor is on.
    pub cursor: u32,
    /// A hash of the question and its answers, leaving out where the cursor
    /// is: moving it does not make it another question.
    pub fingerprint: String,
}

#[derive(Debug)]
pub struct QuestionOption {
    pub number: u32,
    pub label: String,
    pub description: String,
    /// `Type something.` and `Chat about this`: answered by typing, in the
    /// terminal.
    pub typed: bool,
}

impl Question {
    fn to_json(&self) -> Value {
        json!({
            "header": self.header,
            "question": self.text,
            "cursor": self.cursor,
            "fingerprint": self.fingerprint,
            "options": self.options.iter().map(|o| json!({
                "number": o.number, "label": o.label, "description": o.description, "typed": o.typed,
            })).collect::<Vec<_>>(),
        })
    }
}

pub fn question(rows: &[String]) -> Option<Question> {
    let lines = trimmed(rows);
    let footer = lines.last()?.to_lowercase();
    if !(footer.contains("enter to select") && footer.contains("navigate")) {
        return None;
    }
    // The header, `☐ <title>`, opens the form; a row of tabs there (several
    // questions, `✔ Submit`) is not this form.
    let top = (0..lines.len()).rev().find(|&i| lines[i].trim_start().starts_with('☐'))?;
    let header_line = lines[top].trim();
    if header_line.contains("Submit") || header_line.contains('←') || header_line.matches('☐').count() > 1 {
        return None;
    }
    let header = header_line.trim_start_matches('☐').trim().to_owned();
    let mut text: Vec<String> = Vec::new();
    let mut options: Vec<QuestionOption> = Vec::new();
    let mut cursor = None;
    for line in &lines[top + 1..lines.len() - 1] {
        let t = line.trim();
        if t.is_empty() || is_dialog_rule(line) {
            continue;
        }
        if let Some(rest) = t.strip_prefix('│') {
            if !options.is_empty() {
                return None;
            }
            text.push(rest.trim().to_owned());
            continue;
        }
        if let Some((n, label)) = option_line(line) {
            // Multiple choice draws a box per answer.
            if label.starts_with('[') || label.starts_with('☐') || label.starts_with('☒') {
                return None;
            }
            if line.trim_start().starts_with('❯') {
                cursor = Some(n);
            }
            let typed = label.starts_with("Type something") || label.starts_with("Chat about this");
            options.push(QuestionOption { number: n, label, description: String::new(), typed });
            continue;
        }
        // An answer's description, indented under it.
        if line.starts_with("     ") {
            let last = options.last_mut()?;
            if !last.description.is_empty() {
                last.description.push(' ');
            }
            last.description.push_str(t);
            continue;
        }
        return None;
    }
    if text.is_empty() || options.len() < 2 {
        return None;
    }
    if options.iter().enumerate().any(|(k, o)| o.number as usize != k + 1) {
        return None;
    }
    let canonical: Vec<String> = lines[top..]
        .iter()
        .map(|l| l.replacen('❯', " ", 1))
        .collect();
    Some(Question {
        header,
        text: text.join("\n"),
        cursor: cursor?,
        fingerprint: fnv(&canonical.join("\n")),
        options,
    })
}

// ---------------------------------------------------------------- approval

/// A Claude Code permission menu read off the bottom of its pane.
#[derive(Debug)]
pub struct Approval {
    pub subject: Vec<String>,
    pub question: String,
    pub options: Vec<ApprovalOption>,
    /// A hash of the rows it was read from: `input` presses a digit only
    /// while the very same menu is on screen.
    pub fingerprint: String,
}

#[derive(Debug)]
pub struct ApprovalOption {
    pub number: u32,
    pub label: String,
    /// Why this answer needs a second tap; None when one is enough.
    pub risk: Option<&'static str>,
}

impl Approval {
    fn to_json(&self) -> Value {
        json!({
            "subject": self.subject,
            "question": self.question,
            "fingerprint": self.fingerprint,
            "options": self.options.iter().map(|o| json!({
                "number": o.number, "label": o.label, "risk": o.risk,
            })).collect::<Vec<_>>(),
        })
    }
}

/// Recognises the menu only when every part is where Claude draws it: the
/// `Esc to cancel` footer at the very bottom, options numbered 1..n directly
/// above it, and a question ending in `?` directly above those. Anything
/// else, Claude's multi-question form included, is left to the terminal.
///
/// ```text
///  Bash command
///  Create empty file x.txt
/// ╌╌╌╌╌╌
///  touch /tmp/x.txt
/// ╌╌╌╌╌╌
///  Do you want to proceed?
///  ❯ 1. Yes
///    2. Yes, and always allow access to /tmp from this project
///    3. No
///
///  Esc to cancel · Tab to amend
/// ```
pub fn approval(rows: &[String]) -> Option<Approval> {
    const SUBJECT_LIMIT: usize = 14;
    let lines = trimmed(rows);
    if !lines.last()?.contains("Esc to cancel") {
        return None;
    }

    // Options sit directly above the footer, optionally after one blank.
    let mut i = lines.len() as isize - 2;
    while i >= 0 && lines[i as usize].trim().is_empty() {
        i -= 1;
    }
    // Read bottom-up; a wrapped option line (`(shift+tab)` under its label)
    // comes before the option it belongs to and is marked with None.
    let mut raw: Vec<(Option<u32>, String)> = Vec::new();
    while i >= 0 {
        let line = lines[i as usize];
        if let Some((n, label)) = option_line(line) {
            raw.insert(0, (Some(n), label));
        } else if !line.trim().is_empty() && line.starts_with("    ") {
            raw.insert(0, (None, line.trim().to_owned()));
        } else {
            break;
        }
        i -= 1;
    }
    // A continuation with no option above it is not this menu.
    if raw.first().is_some_and(|(n, _)| n.is_none()) {
        return None;
    }
    let mut folded: Vec<(u32, String)> = Vec::new();
    for (n, label) in raw {
        match n {
            Some(n) => folded.push((n, label)),
            None => {
                let last = folded.last_mut()?;
                last.1 = format!("{} {label}", last.1);
            }
        }
    }
    if folded.len() < 2 || folded.iter().enumerate().any(|(k, (n, _))| *n as usize != k + 1) {
        return None;
    }

    while i >= 0 && lines[i as usize].trim().is_empty() {
        i -= 1;
    }
    if i < 0 {
        return None;
    }
    let question = lines[i as usize].trim().to_owned();
    if !question.ends_with('?') {
        return None;
    }

    // The subject runs up from the question to the solid rule Claude draws
    // across the top of the dialog.
    let mut subject: Vec<String> = Vec::new();
    let mut j = i - 1;
    while j >= 0 && subject.len() < SUBJECT_LIMIT * 2 {
        let line = lines[j as usize];
        let rule = is_dialog_rule(line);
        if rule && line.trim().starts_with('─') {
            break;
        }
        if !rule && !line.trim().is_empty() && !line.trim().starts_with("Tip:") {
            let t = line.trim();
            subject.insert(0, t.strip_prefix('│').unwrap_or(t).trim().to_owned());
        }
        j -= 1;
    }
    let command_risk = risky_command(&subject);
    let shown = if subject.len() > SUBJECT_LIMIT {
        let mut s: Vec<String> = subject[..SUBJECT_LIMIT].to_vec();
        s.push("…".into());
        s
    } else {
        subject
    };
    // The whole dialog, from the rule across its top: two menus that ask
    // the same question with the same answers about different commands are
    // different menus. Hashing only the rows from the question down let a
    // digit meant for `touch` approve an `rm -rf` that replaced it in the
    // meantime (found by review, 2026-11-06).
    let top = (0..i as usize)
        .rev()
        .find(|&k| is_dialog_rule(lines[k]) && lines[k].trim().starts_with('─'))
        .unwrap_or(0);
    Some(Approval {
        subject: shown,
        question,
        fingerprint: fnv(&lines[top..].join("\n")),
        options: folded
            .into_iter()
            .map(|(number, label)| ApprovalOption {
                risk: risk_of(&label, command_risk),
                number,
                label,
            })
            .collect(),
    })
}

/// `❯ 1. Yes` or `  2. No`: the number (one or two digits) and the label.
fn option_line(line: &str) -> Option<(u32, String)> {
    let mut rest = line.trim_start();
    if let Some(r) = rest.strip_prefix('❯') {
        rest = r.trim_start();
    }
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() || digits.len() > 2 {
        return None;
    }
    let after = rest[digits.len()..].strip_prefix('.')?;
    if !after.starts_with(char::is_whitespace) {
        return None;
    }
    let label = after.trim();
    if label.is_empty() {
        return None;
    }
    Some((digits.parse().ok()?, label.to_owned()))
}

/// `─`, `━`, `╌`, `┄` or `-`, eight or more, and nothing else on the line.
fn is_dialog_rule(line: &str) -> bool {
    let t = line.trim();
    t.chars().count() >= 8 && t.chars().all(|c| matches!(c, '─' | '━' | '╌' | '┄' | '-'))
}

fn risky_command(subject: &[String]) -> Option<&'static str> {
    let text = subject.join("\n");
    // Shell words, with `;`, `&` and `|` splitting commands; `git` is also
    // `/usr/bin/git`.
    let words: Vec<&str> = text
        // Quotes too: `bash -c "rm -rf /tmp/x"` runs an `rm`.
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')' | '"' | '\'' | '`'))
        .filter(|w| !w.is_empty())
        .collect();
    let is = |w: &str, name: &str| w == name || w.ends_with(&format!("/{name}"));
    let git = |sub: &[&str]| {
        words
            .windows(sub.len() + 1)
            .any(|w| is(w[0], "git") && w[1..].iter().zip(sub).all(|(a, b)| a == b))
    };
    // Words as a regex's `\b` sees them: `kill-server` holds `kill`.
    let parts: Vec<String> = text
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect();
    let part = |name: &str| parts.iter().any(|p| p == name);
    let follows = |a: &str, b: &str| parts.windows(2).any(|w| w[0] == a && w[1] == b);
    if git(&["push"]) {
        return Some("pushes to a remote");
    }
    if git(&["reset", "--hard"]) || git(&["clean"]) || git(&["restore"]) || git(&["checkout", "--"]) {
        return Some("throws away local changes");
    }
    if words.windows(2).any(|w| {
        is(w[0], "rm")
            && w[1].len() > 1
            && w[1].starts_with('-')
            && w[1][1..].chars().all(|c| c.is_ascii_alphabetic())
            && w[1].contains(['r', 'f'])
    }) {
        return Some("deletes files");
    }
    if part("sudo") {
        return Some("runs as root");
    }
    if ["drop", "truncate"]
        .iter()
        .any(|v| follows(v, "table") || follows(v, "database"))
    {
        return Some("deletes data");
    }
    if part("kill") || part("killall") || part("pkill") {
        return Some("stops processes");
    }
    if text.contains("--force") {
        return Some("forces past a safety check");
    }
    None
}

fn risk_of(label: &str, command_risk: Option<&'static str>) -> Option<&'static str> {
    let lower = label.to_lowercase();
    if !lower.starts_with("yes") {
        return None;
    }
    if lower.contains("auto mode") {
        return Some("turns off these questions for the rest of the session");
    }
    if lower.contains("always") || lower.contains("don't ask again") || lower.contains("accept edits") {
        return Some("stops asking about this from now on");
    }
    command_risk
}

/// FNV-1a, 64 bits, as hex: short enough for a command line, and only ever
/// compared with itself.
fn fnv(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(s: &str) -> Vec<String> {
        s.lines().map(str::to_owned).collect()
    }

    const RULE: &str = "────────────────────────────────────────";

    fn idle() -> Vec<String> {
        rows(&format!("● Done.\n\n{RULE}\n❯ \n{RULE}\n  ? for shortcuts\n\n\n"))
    }

    fn working() -> Vec<String> {
        rows(&format!(
            "● Reading files\n\n✻ Jitterbugging… (13s · ↓ 649 tokens · esc to interrupt)\n  ⎿  Tip: Run Claude Code locally\n\n{RULE}\n❯ \n{RULE}\n  esc to interrupt\n"
        ))
    }

    const MENU: &str = "────────────────────────────────────────\n Bash command\n\n   touch /tmp/x.txt\n   Create empty file x.txt\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and always allow access to /tmp from this project\n   3. No\n\n Esc to cancel · Tab to amend\n";

    #[test]
    fn the_idle_prompt_is_a_prompt_and_nothing_else() {
        let r = Reading::from_lines(&idle());
        assert!(r.prompt);
        assert!(r.approval.is_none() && r.panel.is_none() && r.activity.is_none());
    }

    #[test]
    fn a_named_session_rule_is_still_the_box() {
        let s = rows(&format!("──────────────────────── Herdr 手机端通信 ─\n❯ \n{RULE}\n"));
        let r = Reading::from_lines(&s);
        assert!(r.prompt && r.panel.is_none());
    }

    #[test]
    fn the_working_line_is_read_above_the_box_only() {
        let a = activity(&working()).unwrap();
        assert_eq!(a.verb, "Jitterbugging…");
        assert_eq!(a.detail.as_deref(), Some("13s · ↓ 649 tokens"));
        // A bullet in the agent's own output that ends in an ellipsis, far
        // above the box, is not a status.
        let mut s = rows("* Thinking about it…\n");
        s.extend(std::iter::repeat_n(String::from("text"), 10));
        s.extend(idle());
        assert!(activity(&s).is_none());
        assert!(activity(&idle()).is_none());
    }

    #[test]
    fn the_permission_menu_is_read_whole() {
        let a = approval(&rows(MENU)).unwrap();
        assert_eq!(a.question, "Do you want to proceed?");
        assert_eq!(a.options.len(), 3);
        assert_eq!(a.options[1].risk, Some("stops asking about this from now on"));
        assert_eq!(a.options[0].risk, None);
        assert_eq!(a.subject, vec!["Bash command", "touch /tmp/x.txt", "Create empty file x.txt"]);
        let r = Reading::from_lines(&rows(MENU));
        assert!(r.panel.is_none(), "an approval is not also a panel");
        assert!(!r.prompt);
    }

    #[test]
    fn a_risky_command_marks_yes_but_not_no() {
        let m = MENU.replace("touch /tmp/x.txt", "git push --force origin main");
        let a = approval(&rows(&m)).unwrap();
        assert_eq!(a.options[0].risk, Some("pushes to a remote"));
        assert_eq!(a.options[2].risk, None);
        let m = MENU.replace("touch /tmp/x.txt", "rm -rf build");
        assert_eq!(approval(&rows(&m)).unwrap().options[0].risk, Some("deletes files"));
    }

    #[test]
    fn a_wrapped_option_is_folded_into_its_option() {
        let m = MENU.replace(
            "   2. Yes, and always allow access to /tmp from this project\n",
            "   2. Yes, and always allow access to /tmp from this\n      project (shift+tab)\n",
        );
        let a = approval(&rows(&m)).unwrap();
        assert_eq!(a.options[1].label, "Yes, and always allow access to /tmp from this project (shift+tab)");
    }

    #[test]
    fn anything_unlike_the_menu_is_not_one() {
        // No question mark.
        assert!(approval(&rows(&MENU.replace("proceed?", "proceed"))).is_none());
        // Numbers out of order.
        assert!(approval(&rows(&MENU.replace("3. No", "4. No"))).is_none());
        // Footer not at the bottom.
        assert!(approval(&rows(&format!("{MENU}more\n"))).is_none());
        assert!(approval(&idle()).is_none());
    }

    #[test]
    fn the_fingerprint_follows_the_menu() {
        let a = approval(&rows(MENU)).unwrap();
        let b = approval(&rows(&format!("other history\n{MENU}"))).unwrap();
        assert_eq!(a.fingerprint, b.fingerprint);
        let c = approval(&rows(&MENU.replace("3. No", "3. No, tell Claude"))).unwrap();
        assert_ne!(a.fingerprint, c.fingerprint);
    }

    #[test]
    fn the_same_question_about_another_command_is_another_menu() {
        let a = approval(&rows(MENU)).unwrap();
        let b = approval(&rows(&MENU.replace("touch /tmp/x.txt", "rm -rf /tmp/*"))).unwrap();
        assert_ne!(a.fingerprint, b.fingerprint);
    }

    #[test]
    fn a_long_draft_is_still_the_box_and_its_words_are_not_keys() {
        let mut s = rows(&format!("● Done.\n\n{RULE}\n❯ first line of a long draft"));
        s.extend((0..20).map(|i| format!("  line {i} of it, press enter to confirm, esc to cancel")));
        s.extend(rows(&format!("{RULE}\n  ? for shortcuts\n")));
        let r = Reading::from_lines(&s);
        assert!(r.prompt, "the box under a long draft");
        assert!(r.panel.is_none());
    }

    #[test]
    fn a_quoted_command_is_still_risky() {
        for cmd in ["bash -c \"rm -rf /tmp/foo\"", "sh -c 'git push --force'", "rm -rf\"build\""] {
            let a = approval(&rows(&MENU.replace("touch /tmp/x.txt", cmd))).unwrap();
            assert!(a.options[0].risk.is_some(), "{cmd}");
        }
    }

    #[test]
    fn a_panel_is_a_screen_without_the_box_or_with_dialog_keys() {
        let usage = rows("Settings  Status  Config  Usage\n\nCurrent session  3% used\n\nEsc to exit\n");
        assert!(panel(&usage).is_some());
        let mut with_box = idle();
        with_box.push("Enter to select · Esc to go back".into());
        assert!(panel(&with_box).is_some());
        // Working shows `esc to interrupt`, which is not a dialog key.
        assert!(panel(&working()).is_none());
        assert!(panel(&idle()).is_none());
        assert!(panel(&rows("\n\n")).is_none());
    }

    // ------------------------------------------------------------------
    // The phone's own cases, from captures of Claude Code 2.1 on the owner's
    // machine (AttacheAndroid ApprovalPromptsTest, ScreenPanelsTest and
    // AgentActivitiesTest, 2026-11-05/06), carried over when the readers
    // moved here.

    fn v(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|s| s.to_string()).collect()
    }

    fn bash(command: &str, options: &[&str]) -> Vec<String> {
        let rule = "─".repeat(60);
        let dash = "╌".repeat(60);
        let mut s = v(&["⏺ Creating the branch", "", &rule, " Bash command",
            " Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below",
            " Push the fix branch", &dash]);
        s.push(format!(" {command}"));
        s.push(dash.clone());
        s.push(" Do you want to proceed?".into());
        for (i, o) in options.iter().enumerate() {
            s.push(format!("{}{}. {o}", if i == 0 { " ❯ " } else { "   " }, i + 1));
        }
        s.extend(v(&["", " Esc to cancel · Tab to amend", "", ""]));
        s
    }

    #[test]
    fn phone_reads_a_bash_permission_menu() {
        let p = approval(&bash("touch /tmp/x.txt", &["Yes", "Yes, and always allow access to /tmp from this project", "No"])).unwrap();
        assert_eq!(p.question, "Do you want to proceed?");
        assert_eq!(p.subject, vec!["Bash command", "Push the fix branch", "touch /tmp/x.txt"]);
        assert_eq!(p.options.iter().map(|o| o.number).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(p.options[0].risk.is_none() && p.options[1].risk.is_some() && p.options[2].risk.is_none());
    }

    #[test]
    fn phone_a_risky_command_makes_every_yes_ask_twice() {
        let p = approval(&bash("git push origin fix/rail", &["Yes", "No"])).unwrap();
        assert_eq!(p.options[0].risk, Some("pushes to a remote"));
        assert!(p.options[1].risk.is_none());
    }

    #[test]
    fn phone_a_wrapped_option_is_folded_into_its_label() {
        let rule = "─".repeat(60);
        let s = v(&[&rule, " Edit file", " note.txt", " Do you want to make this edit to note.txt?", " ❯ 1. Yes",
            "   2. Yes, and switch to accept edits (auto-approve file edits) for this session", "      (shift+tab)",
            "   3. No", "", " Esc to cancel · Tab to amend"]);
        let p = approval(&s).unwrap();
        assert_eq!(p.options.len(), 3);
        assert_eq!(p.options[1].label, "Yes, and switch to accept edits (auto-approve file edits) for this session (shift+tab)");
        assert!(p.options[1].risk.is_some());
    }

    #[test]
    fn phone_no_footer_no_menu() {
        let mut s = bash("ls", &["Yes", "No"]);
        while s.last().is_some_and(|l| l.trim().is_empty()) {
            s.pop();
        }
        s.pop();
        assert!(approval(&s).is_none());
    }

    #[test]
    fn phone_a_numbered_list_or_the_multi_question_form_is_not_a_menu() {
        assert!(approval(&v(&["Here is the plan:", "1. Fix the parser", "2. Add a test", "", "❯ ", " ? for shortcuts"])).is_none());
        let rule = "─".repeat(60);
        let form = v(&["Which fruits do I like?", "  1. [✔] Apple", "  2. [ ] Banana", &rule, "❯ 3. Chat about this", "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel"]);
        assert!(approval(&form).is_none());
        assert!(approval(&v(&[" Do you want to proceed?", " ❯ 1. Yes", "   3. No", "", " Esc to cancel"])).is_none());
    }

    fn phone_idle() -> Vec<String> {
        let rule = "─".repeat(100);
        v(&["⏺ Rendering the full film now.", "", &rule, "❯ Try \"fix typecheck errors\"", &rule,
            "  …/cmdtest  |  Opus 5.5                     20:09", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent", ""])
    }

    #[test]
    fn phone_panels() {
        assert!(panel(&phone_idle()).is_none());
        let rule = "─".repeat(100);
        let named = v(&["", &format!("{} Herdr 手机端通信与显示 ─", "─".repeat(80)), "❯ ", &rule,
            "  ~/Code/Attache  main  |  Opus 5.5  |  5h ███  used 15%", "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent"]);
        assert!(panel(&named).is_none());
        let mut working = v(&["✻ Jitterbugging… (13s · ↓ 649 tokens · esc to interrupt)", ""]);
        working.extend(phone_idle()[2..].iter().cloned());
        assert!(panel(&working).is_none());
        let usage = v(&["   Total cost:            $0.0000", "   Current session",
            "   ██████████▌                                        21% used", "   Resets 9pm (Asia/Singapore)",
            "   Current week (all models)", "   █▌                                                 3% used",
            "   Subagents               % of usage                                                             ↓", "", ""]);
        let p = panel(&usage).unwrap();
        assert_eq!(p.first().unwrap(), "   Total cost:            $0.0000");
        assert_eq!(p.len(), 7);
        let mut picker = phone_idle();
        picker.pop();
        picker.extend(v(&[" Select model", " ❯ 1. Opus 5.5 (default)", "   2. Sonnet 5.5", "", " Enter to confirm · Esc to exit"]));
        assert_eq!(panel(&picker).unwrap().last().unwrap(), " Enter to confirm · Esc to exit");
    }

    fn phone_working(status: &str, above: &[&str]) -> Vec<String> {
        let rule = "─".repeat(80);
        let mut s = v(above);
        s.extend(v(&[status, "  ⎿  Tip: Run Claude Code locally or remotely using the Claude desktop app · run", "     /desktop", "",
            &rule, "❯ ", &rule, "  ~/Code/Attache   main  |  Opus 5.5  ctx 36%", "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent"]));
        s
    }

    #[test]
    fn phone_activities() {
        let a = |s: &str| activity(&phone_working(s, &[]));
        assert_eq!(a("✻ Jitterbugging… (13s · ↓ 649 tokens · thought for 7s)"),
            Some(Activity { verb: "Jitterbugging…".into(), detail: Some("13s · ↓ 649 tokens · thought for 7s".into()) }));
        assert_eq!(a("✶ Pondering… (2m 4s · ↑ 1.2k tokens · esc to interrupt)"),
            Some(Activity { verb: "Pondering…".into(), detail: Some("2m 4s · ↑ 1.2k tokens".into()) }));
        assert_eq!(a("· Thinking…"), Some(Activity { verb: "Thinking…".into(), detail: None }));
        assert_eq!(a("⏺ All tests pass."), None);
        let rule = "─".repeat(80);
        let mut rows = v(&["* Loading the config…", "", "⏺ Done."]);
        rows.extend((0..10).map(|i| format!("  output line {i}")));
        rows.extend(v(&["", &rule, "❯ ", &rule, "  status line"]));
        assert_eq!(activity(&rows), None);
    }

    fn asked() -> Vec<String> {
        let rule = "─".repeat(80);
        v(&[
            "⏺ Bash(cd /Users/joey/Code/PastePaw; rm pnpm-workspace.yaml && git status --short)",
            "  ⎿  M  .github/workflows/release.yml",
            &rule,
            " ☐ 提交钩子 ",
            "",
            "│ 提交 release.yml 时，pre-commit 钩子失败了。原因是你本机的 pnpm 是 11.7.0，它要求先决定「允不允许 esbuild ",
            "│ 在安装时运行自己的安装脚本」，没决定就直接报错退出。你想怎么处理？",
            "",
            "❯ 1. 这次跳过钩子 (Recommended)",
            "     用 git commit --no-verify 提交并推送 release.yml。钩子只负责格式化 src-tauri 和 frontend/src 里的文件，这次提交没有改这些文件。",
            "  2. 允许 esbuild 运行安装脚本",
            "     在仓库根目录新建 pnpm-workspace.yaml，写上 allowBuilds: esbuild: true，和 release.yml 一起提交。",
            "  3. 先不提交",
            "     release.yml 的改动先留在暂存区，你自己处理 pnpm 的问题后再提交。",
            "  4. Type something.",
            &rule,
            "  5. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
            "",
        ])
    }

    #[test]
    fn a_question_claude_asked_is_read_whole() {
        let q = question(&asked()).unwrap();
        assert_eq!(q.header, "提交钩子");
        assert!(q.text.ends_with("你想怎么处理？"));
        assert_eq!(q.options.len(), 5);
        assert_eq!(q.cursor, 1);
        assert_eq!(q.options[0].label, "这次跳过钩子 (Recommended)");
        assert!(q.options[1].description.starts_with("在仓库根目录新建"));
        assert!(!q.options[2].typed && q.options[3].typed && q.options[4].typed);
        let r = Reading::from_lines(&asked());
        assert!(r.question.is_some() && r.panel.is_none() && r.approval.is_none());
    }

    #[test]
    fn moving_the_cursor_keeps_the_question_and_changing_it_does_not() {
        let a = question(&asked()).unwrap();
        let moved: Vec<String> = asked()
            .into_iter()
            .map(|l| match l.as_str() {
                "❯ 1. 这次跳过钩子 (Recommended)" => "  1. 这次跳过钩子 (Recommended)".to_owned(),
                "  3. 先不提交" => "❯ 3. 先不提交".to_owned(),
                _ => l,
            })
            .collect();
        let b = question(&moved).unwrap();
        assert_eq!(b.cursor, 3);
        assert_eq!(a.fingerprint, b.fingerprint);
        let other: Vec<String> = asked().into_iter().map(|l| l.replace("先不提交", "现在就提交")).collect();
        assert_ne!(a.fingerprint, question(&other).unwrap().fingerprint);
    }

    #[test]
    fn several_questions_or_boxes_are_left_to_the_terminal() {
        let tabs: Vec<String> = asked().into_iter().map(|l| if l.contains("☐ 提交钩子") { "←  ☐ 提交钩子  ☐ 发布  ✔ Submit  →".to_owned() } else { l }).collect();
        assert!(question(&tabs).is_none());
        let boxes: Vec<String> = asked().into_iter().map(|l| l.replace("1. 这次", "1. [ ] 这次")).collect();
        assert!(question(&boxes).is_none());
        assert!(question(&rows(MENU)).is_none());
    }
}
