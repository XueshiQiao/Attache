//! Reads a Claude Code transcript (`~/.claude/projects/…/<session>.jsonl`)
//! into rows, one record at a time.
//!
//! Ported from the phone's `ClaudeTranscript.kt`, whose rules are the
//! desktop app's `ClaudeTranscript.swift`, written from a census of real
//! transcripts. It keeps their bias: dropping something the person said is
//! silent and much worse than showing a line of noise, so every exclusion is
//! a named record kind, never a pattern.
//!
//! - A message typed while the agent works is `type: attachment`,
//!   `attachment.type == queued_command`, and only `origin.kind == human`
//!   separates it from the harness's own notifications. The same message is
//!   also written as `queue-operation`, two to four times; those are ignored.
//! - Most `type: user` records are tool results, not the person.
//! - A tool's result can come in a later line than its call, so earlier
//!   history is read by reading again from further back, not patched in.

use crate::chat::{line_diff, lines, take, DiffLine, Item, Said, Transcript};
use crate::time::parse_iso;
use serde_json::{Map, Value};
use std::collections::HashMap;

const RESULT_LIMIT: usize = 4_000;
const DETAIL_LIMIT: usize = 4_000;
const RELAYED_FROM_ANOTHER_AGENT: &str = "Another Claude session sent a message";
/// Machine-written bodies wearing a user record, by name; counted across
/// 408 transcripts by the desktop app.
const MACHINE_ENVELOPES: [&str; 2] = ["<task-notification", "<system-reminder"];

#[derive(Default)]
pub struct ClaudeTranscript {
    items: Vec<Item>,
    /// Where each tool call sits in `items`, so its result lands on it.
    steps: HashMap<String, usize>,
    said: Said,
    continued_in: Option<String>,
}

impl ClaudeTranscript {
    pub fn new() -> Self {
        Self::default()
    }

    fn read(&mut self, line: &str) {
        let Ok(Value::Object(root)) = serde_json::from_str::<Value>(line) else {
            return;
        };
        // A subagent's conversation belongs to whatever spawned it.
        if bool_of(&root, "isSidechain") {
            return;
        }
        let uuid = str_of(&root, "uuid")
            .map(str::to_owned)
            .unwrap_or_else(|| format!("line-{}", self.items.len()));
        match str_of(&root, "type").unwrap_or("") {
            "attachment" => self.interjection(&root, &uuid),
            "user" => self.user(&root, &uuid),
            "assistant" => self.assistant(&root, &uuid),
            // A slash command and what it printed, as Claude Code 2.1 writes
            // them: `system` records with subtype `local_command`.
            "system" if str_of(&root, "subtype") == Some("local_command") => {
                let content = str_of(&root, "content").unwrap_or("").to_owned();
                self.said_text(&content, &uuid)
            }
            // The request going out, on the main thread: when the prompt
            // cache was last refreshed.
            "api-request" if str_of(&root, "querySource") == Some("repl_main_thread") => {
                if let Some(at) = str_of(&root, "timestamp").and_then(parse_iso) {
                    self.said.last_request_at = Some(at);
                }
            }
            // The session handed on (to a background process, 2.1.311): the
            // rest of this conversation is in another file.
            "continued-in" => {
                if let Some(next) = str_of(&root, "continuedInSessionId") {
                    self.continued_in = Some(next.to_owned());
                }
            }
            // queue-operation, file-history-snapshot, mode, last-prompt,
            // ai-title and the rest of the bookkeeping: nothing anybody said.
            _ => {}
        }
    }

    fn interjection(&mut self, root: &Map<String, Value>, uuid: &str) {
        let Some(a) = root.get("attachment").and_then(Value::as_object) else {
            return;
        };
        if str_of(a, "type") != Some("queued_command") {
            return;
        }
        if a.get("origin")
            .and_then(Value::as_object)
            .and_then(|o| str_of(o, "kind"))
            != Some("human")
        {
            return;
        }
        let prompt = str_of(a, "prompt").unwrap_or("").trim();
        if !prompt.is_empty() {
            self.items.push(Item::User {
                key: uuid.into(),
                text: prompt.into(),
                queued: true,
            });
        }
    }

    fn user(&mut self, root: &Map<String, Value>, uuid: &str) {
        if bool_of(root, "isCompactSummary") {
            self.items.push(Item::Note {
                key: uuid.into(),
                text: "Earlier conversation was compacted".into(),
            });
            return;
        }
        // Skill preambles and the rest of what the harness writes in the
        // user's name; Claude Code marks them itself.
        if bool_of(root, "isMeta") {
            return;
        }
        let Some(message) = root.get("message").and_then(Value::as_object) else {
            return;
        };
        let text = match message.get("content") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Array(blocks)) => {
                if self.attach_results(blocks) {
                    return;
                }
                text_of(blocks)
            }
            _ => return,
        };
        self.said_text(&text, uuid);
    }

    /// A body written in the person's name: what they typed, a command, or
    /// what a command printed.
    fn said_text(&mut self, text: &str, uuid: &str) {
        let mut body = text.trim().to_owned();
        if body.is_empty()
            || body.starts_with("[Image:")
            || body.starts_with(RELAYED_FROM_ANOTHER_AGENT)
        {
            return;
        }
        // What a slash command or a `!` command printed, written right after
        // it; for /usage, /context or /model it is the whole answer.
        if let Some(out) = command_output(&body, uuid) {
            if let Item::Output { text, .. } = &out {
                if !text.is_empty() && text != "(no content)" {
                    self.items.push(out);
                }
            }
            return;
        }
        if MACHINE_ENVELOPES.iter().any(|e| body.starts_with(e)) {
            return;
        }
        if body.starts_with('<') {
            let command = tag("command-name", &body);
            let shell = tag("bash-input", &body);
            if !command.is_empty() {
                let args = tag("command-args", &body);
                body = if args.is_empty() {
                    command
                } else {
                    format!("{command} {args}")
                };
            } else if !shell.is_empty() {
                body = format!("!{shell}");
            } else if body.starts_with("<bash-input>") && body.contains("</bash-input>") {
                return;
            }
        }
        // `[Request interrupted by user]` survives on purpose: the person
        // stopping the agent is a real turn, often the most important one.
        if body.starts_with("[Request interrupted") {
            self.items.push(Item::Note {
                key: uuid.into(),
                text: "Interrupted".into(),
            });
        } else {
            self.items.push(Item::User {
                key: uuid.into(),
                text: body,
                queued: false,
            });
        }
    }

    /// Tool results come back as user-role records. Each is folded into the
    /// step that asked for it; true when the record held any.
    fn attach_results(&mut self, blocks: &[Value]) -> bool {
        let mut any = false;
        for block in blocks.iter().filter_map(Value::as_object) {
            if str_of(block, "type") != Some("tool_result") {
                continue;
            }
            any = true;
            let Some(&index) = str_of(block, "tool_use_id").and_then(|id| self.steps.get(id))
            else {
                continue;
            };
            let text = match block.get("content") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Array(c)) => text_of(c),
                _ => String::new(),
            };
            if let Some(Item::Tool { result, error, .. }) = self.items.get_mut(index) {
                *result = Some(take(&text, RESULT_LIMIT));
                *error = bool_of(block, "is_error");
            }
        }
        any
    }

    fn assistant(&mut self, root: &Map<String, Value>, uuid: &str) {
        let Some(message) = root.get("message").and_then(Value::as_object) else {
            return;
        };
        // Claude Code's `<synthetic>` stand-ins carry no real model.
        if let Some(model) =
            str_of(message, "model").filter(|m| !m.is_empty() && !m.starts_with('<'))
        {
            self.said.model = Some(model.to_owned());
            if let Some(effort) = str_of(root, "effort").filter(|e| !e.is_empty()) {
                self.said.effort = Some(effort.to_owned());
            }
            if let Some(v) = str_of(root, "version") {
                self.said.version = Some(v.to_owned());
            }
            if let Some(u) = message.get("usage").and_then(Value::as_object) {
                // What was sent is what the window holds: fresh input, plus
                // what was read from the cache and what was written to it.
                let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
                let in_window = n("input_tokens")
                    + n("cache_read_input_tokens")
                    + n("cache_creation_input_tokens");
                if in_window > 0 {
                    self.said.context_tokens = Some(in_window);
                }
                if let Some(c) = u.get("cache_creation").and_then(Value::as_object) {
                    let n = |k: &str| c.get(k).and_then(Value::as_u64).unwrap_or(0);
                    if n("ephemeral_1h_input_tokens") > 0 {
                        self.said.cache_ttl = Some(3600);
                    } else if n("ephemeral_5m_input_tokens") > 0 {
                        self.said.cache_ttl = Some(300);
                    }
                }
            }
            if self.said.last_request_at.is_none() {
                self.said.last_request_at = str_of(root, "timestamp").and_then(parse_iso);
            }
        }
        let Some(content) = message.get("content").and_then(Value::as_array) else {
            return;
        };
        for (i, block) in content.iter().enumerate() {
            let Some(block) = block.as_object() else {
                continue;
            };
            let key = format!("{uuid}-{i}");
            match str_of(block, "type").unwrap_or("") {
                "text" => {
                    let t = str_of(block, "text").unwrap_or("").trim();
                    if !t.is_empty() {
                        self.items.push(Item::Agent {
                            key,
                            text: t.into(),
                        });
                    }
                }
                // Current Claude Code writes thinking redacted, signature
                // only; an empty one is not worth a row.
                "thinking" => {
                    let t = str_of(block, "thinking").unwrap_or("").trim();
                    if !t.is_empty() {
                        self.items.push(Item::Thinking {
                            key,
                            text: t.into(),
                        });
                    }
                }
                "tool_use" => {
                    let empty = Map::new();
                    let input = block
                        .get("input")
                        .and_then(Value::as_object)
                        .unwrap_or(&empty);
                    let step = tool_step(key, str_of(block, "name").unwrap_or(""), input);
                    if let Some(id) = str_of(block, "id").filter(|s| !s.is_empty()) {
                        self.steps.insert(id.to_owned(), self.items.len());
                    }
                    self.items.push(step);
                }
                _ => {}
            }
        }
    }
}

impl Transcript for ClaudeTranscript {
    fn accept(&mut self, line: &str) {
        self.read(line);
    }

    fn items(&self) -> &[Item] {
        &self.items
    }

    fn said(&self) -> Said {
        self.said.clone()
    }

    fn continued_in(&self) -> Option<String> {
        self.continued_in.clone()
    }
}

fn tool_step(key: String, name: &str, input: &Map<String, Value>) -> Item {
    let s = |f: &str| str_of(input, f).unwrap_or("").to_owned();
    let file_name = || s("file_path").rsplit('/').next().unwrap_or("").to_owned();
    let summary = match name {
        "Bash" => {
            let d = s("description");
            if d.is_empty() {
                lines(&s("command"))
                    .first()
                    .map(|l| l.to_string())
                    .unwrap_or_default()
            } else {
                d
            }
        }
        "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => file_name(),
        "Grep" | "Glob" => s("pattern"),
        "Task" | "Agent" => s("description"),
        "WebFetch" => s("url"),
        "WebSearch" => s("query"),
        "TodoWrite" => "Updated the plan".into(),
        _ => String::new(),
    };
    let detail = match name {
        "Bash" => s("command"),
        "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => s("file_path"),
        _ => take(
            &serde_json::to_string_pretty(input).unwrap_or_default(),
            DETAIL_LIMIT,
        ),
    };
    let diff = match name {
        "Edit" => line_diff::of(&s("old_string"), &s("new_string")),
        "Write" => lines(&s("content"))
            .into_iter()
            .take(line_diff::MAX_LINES)
            .map(|l| DiffLine::new('+', l))
            .collect(),
        "MultiEdit" => {
            let mut out = Vec::new();
            for (i, e) in input
                .get("edits")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_object)
                .enumerate()
            {
                if i > 0 {
                    out.push(DiffLine::new('…', ""));
                }
                out.extend(line_diff::of(
                    str_of(e, "old_string").unwrap_or(""),
                    str_of(e, "new_string").unwrap_or(""),
                ));
            }
            out
        }
        _ => Vec::new(),
    };
    Item::Tool {
        key,
        name: name.into(),
        summary,
        detail,
        result: None,
        error: false,
        diff,
    }
}

fn command_output(body: &str, uuid: &str) -> Option<Item> {
    let key = uuid.to_owned();
    if body.starts_with("<local-command-stdout>") {
        let t = tag("local-command-stdout", body);
        return Some(Item::Output {
            key,
            text: strip_ansi(&t),
            error: false,
            raw: t.trim_end().into(),
        });
    }
    if body.starts_with("<local-command-stderr>") {
        let t = tag("local-command-stderr", body);
        return Some(Item::Output {
            key,
            text: strip_ansi(&t),
            error: true,
            raw: t.trim_end().into(),
        });
    }
    if body.starts_with("<bash-stdout>") || body.starts_with("<bash-stderr>") {
        let out = strip_ansi(&tag("bash-stdout", body));
        let err = strip_ansi(&tag("bash-stderr", body));
        let text = [out.as_str(), err.as_str()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let error = out.is_empty() && !err.is_empty();
        return Some(Item::Output {
            key,
            raw: text.clone(),
            text,
            error,
        });
    }
    None
}

/// Colour and cursor sequences (`ESC [ … final`), and window-title strings
/// (`ESC ] … BEL` or `ESC ] … ESC \`), taken out.
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                for d in chars.by_ref() {
                    if ('@'..='~').contains(&d) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                while let Some(d) = chars.next() {
                    if d == '\u{7}' {
                        break;
                    }
                    if d == '\u{1b}' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                }
            }
            _ => out.push(c),
        }
    }
    out.trim().to_owned()
}

fn text_of(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter_map(Value::as_object)
        .filter(|b| str_of(b, "type") == Some("text"))
        .filter_map(|b| str_of(b, "text"))
        .collect()
}

fn tag(name: &str, body: &str) -> String {
    let (open, close) = (format!("<{name}>"), format!("</{name}>"));
    match (body.find(&open), body.find(&close)) {
        (Some(o), Some(c)) if c >= o + open.len() => body[o + open.len()..c].trim().to_owned(),
        _ => String::new(),
    }
}

pub fn str_of<'a>(m: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    m.get(k).and_then(Value::as_str)
}

pub fn bool_of(m: &Map<String, Value>, k: &str) -> bool {
    m.get(k).and_then(Value::as_bool).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(lines: &[&str]) -> Vec<Item> {
        let mut t = ClaudeTranscript::new();
        for l in lines {
            t.accept(l);
        }
        t.items().to_vec()
    }

    fn user(k: &str, t: &str) -> Item {
        Item::User {
            key: k.into(),
            text: t.into(),
            queued: false,
        }
    }

    fn output_text(i: &Item) -> (&str, &str) {
        match i {
            Item::Output { key, text, .. } => (key, text),
            other => panic!("not output: {other:?}"),
        }
    }

    #[test]
    fn prompt_and_reply() {
        let items = parse(&[
            r#"{"type":"user","uuid":"u1","message":{"role":"user","content":"修一下滚动 bug"}}"#,
            r#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"好的"}]}}"#,
        ]);
        assert_eq!(
            items,
            vec![
                user("u1", "修一下滚动 bug"),
                Item::Agent {
                    key: "a1-0".into(),
                    text: "好的".into()
                }
            ]
        );
    }

    #[test]
    fn a_tool_result_lands_on_its_step_and_is_not_a_prompt() {
        let items = parse(&[
            r#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build","description":"Build it"}}]}}"#,
            r#"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Build complete","is_error":false}]}}"#,
        ]);
        let [Item::Tool {
            summary,
            detail,
            result,
            error,
            ..
        }] = &items[..]
        else {
            panic!("{items:?}")
        };
        assert_eq!(
            (summary.as_str(), detail.as_str(), result.as_deref(), *error),
            ("Build it", "swift build", Some("Build complete"), false)
        );
    }

    #[test]
    fn a_failed_tool_is_marked() {
        let items = parse(&[
            r#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/y.swift"}}]}}"#,
            r#"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"no such file"}],"is_error":true}]}}"#,
        ]);
        let [Item::Tool {
            summary,
            result,
            error,
            ..
        }] = &items[..]
        else {
            panic!()
        };
        assert_eq!(
            (summary.as_str(), result.as_deref(), *error),
            ("y.swift", Some("no such file"), true)
        );
    }

    #[test]
    fn a_queued_human_message_is_kept_and_the_harness_ones_are_not() {
        let items = parse(&[
            r#"{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"顺便跑测试","origin":{"kind":"human"}}}"#,
            r#"{"type":"attachment","uuid":"q2","attachment":{"type":"queued_command","prompt":"<task-notification>x","origin":{"kind":"task"}}}"#,
            r#"{"type":"queue-operation","operation":"enqueue","content":"顺便跑测试"}"#,
        ]);
        assert_eq!(
            items,
            vec![Item::User {
                key: "q1".into(),
                text: "顺便跑测试".into(),
                queued: true
            }]
        );
    }

    #[test]
    fn machine_records_in_the_users_name_are_dropped() {
        let items = parse(&[
            r#"{"type":"user","uuid":"m","isMeta":true,"message":{"content":"skill preamble"}}"#,
            r#"{"type":"user","uuid":"n","message":{"content":"<task-notification>done</task-notification>"}}"#,
            r#"{"type":"user","uuid":"s","isSidechain":true,"message":{"content":"subagent prompt"}}"#,
            r#"{"type":"user","uuid":"i","message":{"content":[{"type":"text","text":"[Image: 1200x800]"}]}}"#,
        ]);
        assert!(items.is_empty());
    }

    #[test]
    fn a_question_about_html_is_not_mistaken_for_an_envelope() {
        let items = parse(&[
            r#"{"type":"user","uuid":"h","message":{"content":"<div>why does this break?</div>"}}"#,
        ]);
        assert_eq!(items, vec![user("h", "<div>why does this break?</div>")]);
    }

    #[test]
    fn slash_and_shell_commands_are_unwrapped() {
        let items = parse(&[
            r#"{"type":"user","uuid":"c","message":{"content":"<command-message>clear</command-message><command-name>/clear</command-name><command-args></command-args>"}}"#,
            r#"{"type":"user","uuid":"b","message":{"content":"<bash-input>git status</bash-input>"}}"#,
            r#"{"type":"user","uuid":"o","message":{"content":"<bash-stdout>On branch main</bash-stdout><bash-stderr></bash-stderr>"}}"#,
        ]);
        assert_eq!(items[..2], [user("c", "/clear"), user("b", "!git status")]);
        assert_eq!(output_text(&items[2]), ("o", "On branch main"));
    }

    #[test]
    fn an_interruption_is_a_note() {
        let items = parse(&[
            r#"{"type":"user","uuid":"x","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        ]);
        assert_eq!(
            items,
            vec![Item::Note {
                key: "x".into(),
                text: "Interrupted".into()
            }]
        );
    }

    #[test]
    fn redacted_thinking_is_not_a_row() {
        assert!(parse(&[r#"{"type":"assistant","uuid":"a","message":{"content":[{"type":"thinking","thinking":"","signature":"abc"}]}}"#]).is_empty());
    }

    #[test]
    fn a_slash_commands_result_is_shown() {
        let items = parse(&[
            r#"{"type":"user","uuid":"c","message":{"content":"<command-name>/usage</command-name><command-message>usage</command-message><command-args></command-args>"}}"#,
            r#"{"type":"user","uuid":"r","message":{"content":"<local-command-stdout>Current session: 21% used\nCurrent week: 3% used</local-command-stdout>"}}"#,
            r#"{"type":"user","uuid":"e","message":{"content":"<local-command-stdout>(no content)</local-command-stdout>"}}"#,
            r#"{"type":"user","uuid":"z","message":{"content":"<local-command-stdout></local-command-stdout>"}}"#,
        ]);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0], user("c", "/usage"));
        assert_eq!(
            output_text(&items[1]),
            ("r", "Current session: 21% used\nCurrent week: 3% used")
        );
    }

    /// `/context` as Claude Code 2.1 recorded it on this machine.
    #[test]
    fn a_command_recorded_as_system_records_is_shown_too() {
        let items = parse(&[
            r#"{"type":"system","subtype":"local_command","uuid":"s1","isMeta":false,"level":"info","content":"<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args></command-args>"}"#,
            r#"{"type":"system","subtype":"local_command","uuid":"s2","isMeta":false,"level":"info","content":"<local-command-stdout> \u001b[1mContext Usage\u001b[22m\n\u001b[38;5;140m⛁ ⛁\u001b[39m  \u001b[38;5;246m513.9k/1m tokens (51%)\u001b[39m</local-command-stdout>"}"#,
            r###"{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"## Context Usage\n\n**Tokens:** 513.9k / 1m (51%)"}}"###,
            r#"{"type":"system","subtype":"api_error","uuid":"s3","content":"retrying"}"#,
        ]);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0], user("s1", "/context"));
        assert_eq!(
            output_text(&items[1]),
            ("s2", "Context Usage\n⛁ ⛁  513.9k/1m tokens (51%)")
        );
        // The raw form keeps the colours.
        let Item::Output { raw, .. } = &items[1] else {
            panic!()
        };
        assert!(raw.contains("\u{1b}[1m"));
    }

    #[test]
    fn terminal_colours_and_titles_are_taken_out_of_a_result() {
        let items = parse(&[
            r#"{"type":"user","uuid":"r","message":{"content":"<local-command-stdout>\u001b[1mContext Usage\u001b[22m\n\u001b[38;5;244m⛀ \u001b[38;5;246m⛁ ⛶\u001b[0m</local-command-stdout>"}}"#,
        ]);
        assert_eq!(output_text(&items[0]), ("r", "Context Usage\n⛀ ⛁ ⛶"));
        assert_eq!(
            strip_ansi("\u{1b}]0;title\u{7}text\u{1b}]2;t\u{1b}\\!"),
            "text!"
        );
    }

    #[test]
    fn an_edit_tool_call_carries_its_diff() {
        let items = parse(&[
            r#"{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/x/a.kt","old_string":"val x = 1","new_string":"val x = 2"}}]}}"#,
        ]);
        let [Item::Tool { summary, diff, .. }] = &items[..] else {
            panic!()
        };
        assert_eq!(summary, "a.kt");
        assert_eq!(
            diff,
            &vec![
                DiffLine::new('-', "val x = 1"),
                DiffLine::new('+', "val x = 2")
            ]
        );
    }

    #[test]
    fn garbage_lines_are_skipped() {
        assert!(parse(&["not json", "{\"type\":", ""]).is_empty());
    }

    #[test]
    fn what_the_replies_say_about_the_agent() {
        let mut t = ClaudeTranscript::new();
        for l in [
            r#"{"type":"api-request","querySource":"repl_main_thread","timestamp":"2026-11-06T05:22:58.650Z"}"#,
            r#"{"type":"assistant","uuid":"a","effort":"high","version":"2.1.311","timestamp":"2026-11-06T05:23:10.000Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":538052,"cache_creation_input_tokens":1264,"cache_creation":{"ephemeral_1h_input_tokens":1264,"ephemeral_5m_input_tokens":0}},"content":[]}}"#,
            // A subagent's reply never speaks for the session.
            r#"{"type":"assistant","uuid":"b","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":9},"content":[]}}"#,
            // Nor does a stand-in.
            r#"{"type":"assistant","uuid":"c","message":{"model":"<synthetic>","content":[]}}"#,
            // A subagent's request does not refresh the session's cache.
            r#"{"type":"api-request","querySource":"agent:task","timestamp":"2026-11-06T06:00:00.000Z"}"#,
        ] {
            t.accept(l);
        }
        let s = t.said();
        assert_eq!(s.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(s.effort.as_deref(), Some("high"));
        assert_eq!(s.context_tokens, Some(539_318));
        assert_eq!(s.cache_ttl, Some(3600));
        assert_eq!(s.last_request_at, Some(1_793_942_578));
        assert_eq!(s.version.as_deref(), Some("2.1.311"));
    }

    #[test]
    fn a_session_handed_on_names_where_it_went() {
        let mut t = ClaudeTranscript::new();
        t.accept(r#"{"type":"continued-in","sessionId":"old","continuedInSessionId":"c94cb7d8-1e11-4a15-b95d-b432b56207bb"}"#);
        assert_eq!(
            t.continued_in().as_deref(),
            Some("c94cb7d8-1e11-4a15-b95d-b432b56207bb")
        );
    }
}
