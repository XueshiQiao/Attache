//! Reads agy's own export of a conversation,
//! `~/.gemini/antigravity-cli/brain/<conversation>/.system_generated/logs/transcript_full.jsonl`,
//! into rows. Ported from the phone's `AgyTranscript.kt`; the shapes were
//! checked against 484 such files, agy 1.4.12, 2026-11-05.
//!
//! One JSON object a line, each a step: `step_index`, `type` (`USER_INPUT`,
//! `PLANNER_RESPONSE`, `GENERIC` for a tool's result, `SYSTEM_MESSAGE`,
//! `CHECKPOINT`), `status` and `content`.
//!
//! - The ledger is appended to, never rewritten. A rewind shows up as a step
//!   whose number is not above the last one; every step numbered from it on
//!   is dropped, as herdr does. The same rule drops a step written twice.
//! - A tool's results follow the planner response that called it, one
//!   `GENERIC` step per call in call order (10,262 of 10,272 calls here);
//!   the ledger carries no call id.
//! - Only `DONE` steps are shown, and `ERROR` for a result.

use crate::chat::{line_diff, lines, take, DiffLine, Item, Said, Transcript};
use crate::claude_transcript::str_of;
use serde_json::{Map, Value};
use std::collections::VecDeque;

const RESULT_LIMIT: usize = 4_000;
const DETAIL_LIMIT: usize = 4_000;

#[derive(Default)]
pub struct AgyTranscript {
    steps: Vec<(i64, String)>,
    items: Vec<Item>,
    /// The latest planner response's tool calls still waiting for a result,
    /// as positions in `items`.
    waiting: VecDeque<usize>,
    context_tokens: Option<u64>,
}

impl AgyTranscript {
    pub fn new() -> Self {
        Self::default()
    }

    fn rebuild(&mut self) {
        self.items.clear();
        self.waiting.clear();
        self.context_tokens = None;
        let steps = std::mem::take(&mut self.steps);
        for (index, line) in &steps {
            if let Ok(Value::Object(step)) = serde_json::from_str::<Value>(line) {
                self.read(&step, *index);
            }
        }
        self.steps = steps;
    }

    fn read(&mut self, step: &Map<String, Value>, index: i64) {
        let status = str_of(step, "status").unwrap_or("");
        let content = str_of(step, "content").unwrap_or("");
        let key = format!("agy-{index}");
        match str_of(step, "type").unwrap_or("") {
            "USER_INPUT" => {
                if status != "DONE" {
                    return;
                }
                self.waiting.clear();
                let images = step
                    .get("media")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len);
                let mut parts = Vec::new();
                let text = user_text(content);
                if !text.trim().is_empty() {
                    parts.push(text.trim().to_owned());
                }
                if images > 0 {
                    parts.push(if images == 1 {
                        "[1 image]".into()
                    } else {
                        format!("[{images} images]")
                    });
                }
                if !parts.is_empty() {
                    self.items.push(Item::User {
                        key,
                        text: parts.join("\n"),
                        queued: false,
                    });
                }
            }
            "PLANNER_RESPONSE" => {
                if status != "DONE" {
                    return;
                }
                self.waiting.clear();
                // What was sent is what the window holds: fresh input plus
                // what was read from the cache.
                let n = |k: &str| step.get(k).and_then(Value::as_u64).unwrap_or(0);
                let in_window = n("input_tokens") + n("cache_read_tokens");
                if in_window > 0 {
                    self.context_tokens = Some(in_window);
                }
                let thinking = str_of(step, "thinking").unwrap_or("").trim();
                if !thinking.is_empty() {
                    self.items.push(Item::Thinking {
                        key: format!("{key}-t"),
                        text: thinking.into(),
                    });
                }
                if !content.trim().is_empty() {
                    self.items.push(Item::Agent {
                        key: format!("{key}-a"),
                        text: content.trim().into(),
                    });
                }
                let empty = Map::new();
                for (i, call) in step
                    .get("tool_calls")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_object)
                    .enumerate()
                {
                    self.waiting.push_back(self.items.len());
                    let args = call
                        .get("args")
                        .and_then(Value::as_object)
                        .unwrap_or(&empty);
                    self.items.push(tool_step(
                        format!("{key}-{i}"),
                        str_of(call, "name").unwrap_or(""),
                        args,
                    ));
                }
            }
            "GENERIC" => {
                if status != "DONE" && status != "ERROR" {
                    return;
                }
                let (text, failed) = result(content);
                let error = failed || status == "ERROR";
                let text = take(&text, RESULT_LIMIT);
                match self.waiting.pop_front() {
                    Some(at) if matches!(self.items.get(at), Some(Item::Tool { .. })) => {
                        if let Some(Item::Tool {
                            result, error: e, ..
                        }) = self.items.get_mut(at)
                        {
                            *result = Some(text);
                            *e = error;
                        }
                    }
                    _ if !text.trim().is_empty() => self.items.push(Item::Tool {
                        key,
                        name: "Tool output".into(),
                        summary: String::new(),
                        detail: String::new(),
                        result: Some(text),
                        error,
                        diff: Vec::new(),
                    }),
                    _ => {}
                }
            }
            // SYSTEM_MESSAGE is the harness talking to the model, CHECKPOINT
            // its own bookkeeping: nothing anybody said.
            _ => {}
        }
    }
}

impl Transcript for AgyTranscript {
    fn accept(&mut self, line: &str) {
        let Ok(Value::Object(step)) = serde_json::from_str::<Value>(line) else {
            return;
        };
        let Some(index) = step
            .get("step_index")
            .and_then(Value::as_i64)
            .filter(|i| *i >= 0)
        else {
            return;
        };
        if self.steps.last().is_some_and(|(last, _)| index <= *last) {
            while self.steps.last().is_some_and(|(last, _)| *last >= index) {
                self.steps.pop();
            }
            self.steps.push((index, line.to_owned()));
            self.rebuild();
        } else {
            self.steps.push((index, line.to_owned()));
            self.read(&step, index);
        }
    }

    fn items(&self) -> &[Item] {
        &self.items
    }

    fn said(&self) -> Said {
        // agy writes no model into this file; its settings supply that.
        Said {
            context_tokens: self.context_tokens,
            ..Said::default()
        }
    }
}

/// agy's tools under the names the clients already draw: a command's output
/// is shown without a tap when the step is called `Bash`, a file change's
/// diff whatever it is called. Anything else keeps agy's name.
fn tool_step(key: String, name: &str, args: &Map<String, Value>) -> Item {
    let s = |f: &str| str_of(args, f).unwrap_or("").to_owned();
    let path = [s("AbsolutePath"), s("TargetFile"), s("Path")]
        .into_iter()
        .find(|p| !p.is_empty())
        .unwrap_or_default();
    let shown = match name {
        "run_command" => "Bash",
        "view_file" | "read_file" => "Read",
        "edit_file" | "replace_file_content" | "multi_replace_file_content" => "Edit",
        "write_file" | "write_to_file" => "Write",
        "grep_search" => "Grep",
        "find_by_name" => "Glob",
        "list_dir" => "List",
        "search_web" => "WebSearch",
        "read_url_content" => "WebFetch",
        "invoke_subagent" => "Agent",
        other => other,
    };
    // agy writes its own one-line summary on most calls.
    let mut summary = s("toolSummary");
    if summary.is_empty() {
        summary = match name {
            "run_command" => lines(&s("CommandLine"))
                .first()
                .map(|l| l.to_string())
                .unwrap_or_default(),
            "grep_search" => s("Query"),
            "find_by_name" => s("Pattern"),
            "list_dir" => s("DirectoryPath")
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_owned(),
            "search_web" => s("query"),
            "read_url_content" => s("Url"),
            "invoke_subagent" => s("Role"),
            _ => path.rsplit('/').next().unwrap_or("").to_owned(),
        };
    }
    let detail = if name == "run_command" {
        s("CommandLine")
    } else if !path.is_empty() {
        path.clone()
    } else {
        take(
            &serde_json::to_string_pretty(args).unwrap_or_default(),
            DETAIL_LIMIT,
        )
    };
    let diff = match name {
        "edit_file" => line_diff::of(&s("Target"), &s("Replacement")),
        "replace_file_content" => line_diff::of(&s("TargetContent"), &s("ReplacementContent")),
        "write_file" | "write_to_file" => {
            let body = if s("Content").is_empty() {
                s("CodeContent")
            } else {
                s("Content")
            };
            lines(&body)
                .into_iter()
                .take(line_diff::MAX_LINES)
                .map(|l| DiffLine::new('+', l))
                .collect()
        }
        _ => Vec::new(),
    };
    Item::Tool {
        key,
        name: shown.into(),
        summary,
        detail,
        result: None,
        error: false,
        diff,
    }
}

/// A prompt without the wrapper agy puts around it:
/// `<USER_REQUEST>…</USER_REQUEST>` and the metadata after it.
pub fn user_text(text: &str) -> String {
    let Some(rest) = text.strip_prefix("<USER_REQUEST>") else {
        return text.to_owned();
    };
    match rest.rfind("</USER_REQUEST>") {
        Some(end) => rest[..end].trim_matches('\n').to_owned(),
        None => text.to_owned(),
    }
}

/// A tool result without agy's timestamps at the top; for a command, only
/// what it printed, and whether it exited non-zero. As agy writes it:
/// `Command exited with code 0.`, a blank line, `Command output:` and the
/// output.
pub fn result(content: &str) -> (String, bool) {
    // Line by line, which also turns a command's `\r\n` into `\n`.
    let body = lines(content)
        .into_iter()
        .skip_while(|l| l.starts_with("Created At: ") || l.starts_with("Completed At: "))
        .collect::<Vec<_>>()
        .join("\n");
    let body = body.trim();
    let code = body
        .strip_prefix("Command exited with code ")
        .and_then(|rest| {
            rest.chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse::<i64>()
                .ok()
        });
    let Some(code) = code else {
        return (body.to_owned(), false);
    };
    let output = body
        .split_once("Command output:\n")
        .map(|(_, o)| without_spinner(o))
        .unwrap_or_default();
    (
        if output.is_empty() {
            body.to_owned()
        } else {
            output
        },
        code != 0,
    )
}

/// A command that draws a spinner leaves every frame in its output as a
/// line of its own, one braille cell and a blank line each: hundreds of
/// lines of nothing. Those lines go and the blank runs they leave close up;
/// a braille character inside real text stays.
fn without_spinner(output: &str) -> String {
    let kept: Vec<&str> = lines(output)
        .into_iter()
        .filter(|l| {
            l.trim().is_empty()
                || !l
                    .chars()
                    .all(|c| c.is_whitespace() || ('\u{2800}'..='\u{28FF}').contains(&c))
        })
        .collect();
    let mut out: Vec<&str> = Vec::new();
    let mut blanks = 0;
    for l in kept {
        if l.trim().is_empty() {
            blanks += 1;
            if blanks > 1 {
                continue;
            }
        } else {
            blanks = 0;
        }
        out.push(l);
    }
    out.join("\n").trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Step shapes from agy 1.4.12's exports on this machine, 2026-11-05.
    fn step(index: i64, kind: &str, status: &str, extra: Value) -> String {
        let mut v = json!({ "step_index": index, "type": kind, "status": status, "created_at": "2026-11-05T14:53:57Z" });
        for (k, x) in extra.as_object().unwrap() {
            v[k] = x.clone();
        }
        v.to_string()
    }

    fn user(i: i64, text: &str) -> String {
        step(
            i,
            "USER_INPUT",
            "DONE",
            json!({ "content": format!("<USER_REQUEST>\n{text}\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-05T22:53:57+08:00.\n</ADDITIONAL_METADATA>") }),
        )
    }

    fn command(i: i64, line: &str, summary: &str) -> String {
        step(
            i,
            "PLANNER_RESPONSE",
            "DONE",
            json!({ "input_tokens": 2873, "cache_read_tokens": 101439, "content": "",
            "tool_calls": [{ "name": "run_command", "args": { "CommandLine": line, "WaitMsBeforeAsync": 10000, "toolSummary": summary } }] }),
        )
    }

    fn output(i: i64, code: i32, printed: &str) -> String {
        step(
            i,
            "GENERIC",
            "DONE",
            json!({ "content": format!("Created At: 2026-10-25T15:08:19+08:00\nCompleted At: 2026-10-25T15:08:19+08:00\nCommand exited with code {code}.\n\nCommand output:\n{printed}") }),
        )
    }

    fn answer(i: i64, text: &str) -> String {
        step(
            i,
            "PLANNER_RESPONSE",
            "DONE",
            json!({ "input_tokens": 3000, "cache_read_tokens": 104313, "content": text }),
        )
    }

    fn read(lines: &[String]) -> AgyTranscript {
        let mut t = AgyTranscript::new();
        for l in lines {
            t.accept(l);
        }
        t
    }

    fn texts(t: &AgyTranscript) -> Vec<String> {
        t.items()
            .iter()
            .map(|i| match i {
                Item::User { text, .. } | Item::Agent { text, .. } => text.clone(),
                Item::Tool { name, .. } => format!("[{name}]"),
                other => format!("{other:?}"),
            })
            .collect()
    }

    #[test]
    fn a_turn_reads_as_prompt_command_and_answer() {
        let t = read(&[
            user(0, "现在查询的频率是多少呀？"),
            step(
                1,
                "SYSTEM_MESSAGE",
                "DONE",
                json!({ "content": "The following is a <SYSTEM_MESSAGE> not actually sent by the user." }),
            ),
            command(2, "ls -la", "List the folder"),
            output(3, 0, "total 448\n.git"),
            answer(4, "每 **三秒** 一次。"),
        ]);
        assert_eq!(
            texts(&t),
            vec!["现在查询的频率是多少呀？", "[Bash]", "每 **三秒** 一次。"]
        );
        let Item::Tool {
            summary,
            detail,
            result,
            error,
            ..
        } = &t.items()[1]
        else {
            panic!()
        };
        assert_eq!(
            (summary.as_str(), detail.as_str(), result.as_deref(), *error),
            ("List the folder", "ls -la", Some("total 448\n.git"), false)
        );
        assert_eq!(t.said().context_tokens, Some(107_313));
        assert_eq!(t.said().model, None);
    }

    #[test]
    fn results_land_on_their_calls_in_order_and_a_failed_command_is_an_error() {
        let t = read(&[
            step(
                0,
                "PLANNER_RESPONSE",
                "DONE",
                json!({ "content": "", "tool_calls": [
                { "name": "run_command", "args": { "CommandLine": "false" } },
                { "name": "edit_file", "args": { "Path": "/w/a.txt", "Target": "old", "Replacement": "new" } }] }),
            ),
            output(1, 1, "boom"),
            step(
                2,
                "GENERIC",
                "DONE",
                json!({ "content": "Created At: x\nCompleted At: y\nMade 1 replacement in /w/a.txt starting at line 15 (+1/-1 lines)." }),
            ),
        ]);
        let [Item::Tool {
            result: r1,
            error: e1,
            ..
        }, Item::Tool {
            name,
            summary,
            diff,
            result: r2,
            ..
        }] = t.items()
        else {
            panic!()
        };
        assert_eq!((r1.as_deref(), *e1), (Some("boom"), true));
        assert_eq!((name.as_str(), summary.as_str()), ("Edit", "a.txt"));
        assert_eq!(
            diff,
            &vec![DiffLine::new('-', "old"), DiffLine::new('+', "new")]
        );
        assert!(r2.as_deref().unwrap().starts_with("Made 1 replacement"));
    }

    #[test]
    fn a_spinner_leaves_no_lines_in_a_commands_output() {
        let t = read(&[
            command(0, "gh run watch", "Watch"),
            output(
                1,
                0,
                "\n\n\u{28fe}\n\n\u{28fd}\n\n\n\u{28fb}\n\nrun 123 completed\n\u{28ff} done",
            ),
        ]);
        let Item::Tool { result, .. } = &t.items()[0] else {
            panic!()
        };
        assert_eq!(result.as_deref(), Some("run 123 completed\n\u{28ff} done"));
    }

    #[test]
    fn a_rewind_drops_every_step_from_where_it_restarts() {
        // As in a real export: step 583 written again after 593.
        let t = read(&[
            user(583, "第一次问"),
            answer(584, "第一次答"),
            command(592, "ls", "List"),
            output(593, 0, "x"),
            user(583, "改过的问题"),
            answer(584, "新的回答"),
        ]);
        assert_eq!(texts(&t), vec!["改过的问题", "新的回答"]);
    }

    #[test]
    fn a_step_written_twice_or_after_an_invalid_one_is_shown_once() {
        let t = read(&[
            command(9, "ls", "List"),
            step(
                11,
                "GENERIC",
                "INVALID",
                json!({ "content": "Created At: x" }),
            ),
            output(10, 0, "one"),
            answer(12, "done"),
            answer(12, "done"),
        ]);
        assert_eq!(t.items().len(), 2);
        let Item::Tool { result, .. } = &t.items()[0] else {
            panic!()
        };
        assert_eq!(result.as_deref(), Some("one"));
    }

    #[test]
    fn a_running_step_is_not_shown_and_an_image_is_named() {
        let t = read(&[
            step(
                0,
                "USER_INPUT",
                "DONE",
                json!({ "content": "<USER_REQUEST>\n看这张图\n</USER_REQUEST>",
                "media": [{ "mime_type": "image/png", "uri": "/h/.gemini/antigravity-cli/brain/x/.user_uploaded/uploaded_media_0.png" }] }),
            ),
            command(1, "sleep 100", "Wait"),
            step(
                2,
                "GENERIC",
                "RUNNING",
                json!({ "content": "Created At: x\nCommand is running" }),
            ),
        ]);
        assert_eq!(texts(&t)[0], "看这张图\n[1 image]");
        let Item::Tool { result, .. } = &t.items()[1] else {
            panic!()
        };
        assert_eq!(result, &None);
    }

    #[test]
    fn a_prompt_loses_agys_wrapper() {
        assert_eq!(
            user_text(
                "<USER_REQUEST>\nhi\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"
            ),
            "hi"
        );
        assert_eq!(user_text("plain"), "plain");
    }
}
