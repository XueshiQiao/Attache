//! The rows of a conversation, as every client draws them, and how a
//! transcript reader hands them out.

use serde_json::{json, Value};

/// One row. `key` is stable across rereads of the same file, so a client
/// can keep what it drew.
#[derive(Clone, Debug, PartialEq)]
pub enum Item {
    User {
        key: String,
        text: String,
        queued: bool,
    },
    Agent {
        key: String,
        text: String,
    },
    Thinking {
        key: String,
        text: String,
    },
    /// A tool call, with its result once one has come back.
    Tool {
        key: String,
        name: String,
        summary: String,
        detail: String,
        result: Option<String>,
        error: bool,
        /// For a file change, what changed, line by line.
        diff: Vec<DiffLine>,
    },
    /// What a slash command or a `!` shell command printed; `raw` keeps the
    /// colour codes (`/context` draws its chart in colours).
    Output {
        key: String,
        text: String,
        error: bool,
        raw: String,
    },
    Note {
        key: String,
        text: String,
    },
}

/// One line of a file change: `kind` is `+`, `-`, ` ` for context, or `…`
/// where unchanged lines were left out.
#[derive(Clone, Debug, PartialEq)]
pub struct DiffLine {
    pub kind: char,
    pub text: String,
}

impl DiffLine {
    pub fn new(kind: char, text: &str) -> DiffLine {
        DiffLine {
            kind,
            text: text.to_owned(),
        }
    }
}

impl Item {
    pub fn to_json(&self) -> Value {
        match self {
            Item::User { key, text, queued } => {
                json!({ "type": "user", "key": key, "text": text, "queued": queued })
            }
            Item::Agent { key, text } => json!({ "type": "agent", "key": key, "text": text }),
            Item::Thinking { key, text } => json!({ "type": "thinking", "key": key, "text": text }),
            Item::Tool {
                key,
                name,
                summary,
                detail,
                result,
                error,
                diff,
            } => json!({
                "type": "tool", "key": key, "name": name, "summary": summary, "detail": detail,
                "result": result, "error": error,
                "diff": diff.iter().map(|d| json!([d.kind.to_string(), d.text])).collect::<Vec<_>>(),
            }),
            Item::Output {
                key,
                text,
                error,
                raw,
            } => json!({ "type": "output", "key": key, "text": text, "error": error, "raw": raw }),
            Item::Note { key, text } => json!({ "type": "note", "key": key, "text": text }),
        }
    }
}

/// What a transcript says about the agent itself, as of its latest reply.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Said {
    pub model: Option<String>,
    pub effort: Option<String>,
    /// What the latest request put in the window.
    pub context_tokens: Option<u64>,
    pub version: Option<String>,
    /// When the latest main-thread request went out, epoch seconds: the
    /// prompt cache's lifetime runs from the request.
    pub last_request_at: Option<u64>,
    /// The cache lifetime the latest requests wrote, in seconds.
    pub cache_ttl: Option<u64>,
}

/// A reader for one agent's transcript, fed one line at a time.
pub trait Transcript {
    fn accept(&mut self, line: &str);
    fn items(&self) -> &[Item];
    fn said(&self) -> Said;
    /// The session this conversation continues in, when the file says it
    /// moved on (Claude's `continued-in`).
    fn continued_in(&self) -> Option<String> {
        None
    }
}

/// The first row that differs, for sending only what changed: almost
/// always the tail (a new reply, a tool's result, a rewind).
pub fn first_change(old: &[Item], new: &[Item]) -> Option<usize> {
    let same = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    (same < old.len() || same < new.len()).then_some(same)
}

/// Kotlin's `String.lines()`, which the clients' readers were written
/// against: a trailing newline leaves an empty last line.
pub fn lines(s: &str) -> Vec<&str> {
    s.split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect()
}

/// At most `n` characters.
pub fn take(s: &str, n: usize) -> String {
    match s.char_indices().nth(n) {
        Some((i, _)) => s[..i].to_owned(),
        None => s.to_owned(),
    }
}

/// A line diff for a file change, as the terminal draws one: changed lines
/// with two lines of context, and the unchanged stretches between left out.
pub mod line_diff {
    use super::{lines, DiffLine};

    /// Past this many lines a side, the change is shown as removed then
    /// added rather than aligned: the alignment is quadratic.
    pub const MAX_LINES: usize = 400;
    const CONTEXT: usize = 2;

    pub fn of(old: &str, new: &str) -> Vec<DiffLine> {
        let a: Vec<&str> = if old.is_empty() {
            Vec::new()
        } else {
            lines(old)
        };
        let b: Vec<&str> = if new.is_empty() {
            Vec::new()
        } else {
            lines(new)
        };
        if a.len() > MAX_LINES || b.len() > MAX_LINES {
            return a
                .iter()
                .take(MAX_LINES)
                .map(|l| DiffLine::new('-', l))
                .chain(b.iter().take(MAX_LINES).map(|l| DiffLine::new('+', l)))
                .collect();
        }
        // Longest common subsequence, then walked forwards.
        let mut lcs = vec![vec![0u32; b.len() + 1]; a.len() + 1];
        for i in (0..a.len()).rev() {
            for j in (0..b.len()).rev() {
                lcs[i][j] = if a[i] == b[j] {
                    lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i + 1][j].max(lcs[i][j + 1])
                };
            }
        }
        let mut all = Vec::new();
        let (mut i, mut j) = (0, 0);
        while i < a.len() || j < b.len() {
            if i < a.len() && j < b.len() && a[i] == b[j] {
                all.push(DiffLine::new(' ', a[i]));
                i += 1;
                j += 1;
            } else if i < a.len() && (j == b.len() || lcs[i + 1][j] >= lcs[i][j + 1]) {
                // Removed before added where both fit, as the terminal draws it.
                all.push(DiffLine::new('-', a[i]));
                i += 1;
            } else {
                all.push(DiffLine::new('+', b[j]));
                j += 1;
            }
        }
        // Keep each change with its context; fold what lies between.
        let mut keep = vec![false; all.len()];
        for (k, line) in all.iter().enumerate() {
            if line.kind != ' ' {
                let around = k.saturating_sub(CONTEXT)..=(k + CONTEXT).min(all.len() - 1);
                keep[around].fill(true);
            }
        }
        let mut out = Vec::new();
        let mut folded = false;
        for (k, line) in all.into_iter().enumerate() {
            if keep[k] {
                out.push(line);
                folded = false;
            } else if !folded {
                out.push(DiffLine::new('…', ""));
                folded = true;
            }
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn render(d: &[DiffLine]) -> Vec<String> {
            d.iter().map(|l| format!("{}{}", l.kind, l.text)).collect()
        }

        #[test]
        fn a_change_keeps_two_lines_of_context_and_folds_the_rest() {
            let old = "1\n2\n3\n4\n5\n6\n7\n8\n9";
            let new = "1\n2\n3\n4\nfive\n6\n7\n8\n9";
            assert_eq!(
                render(&of(old, new)),
                vec!["…", " 3", " 4", "-5", "+five", " 6", " 7", "…"]
            );
        }

        #[test]
        fn a_new_file_is_all_added_and_an_emptied_one_all_removed() {
            assert_eq!(render(&of("", "a\nb")), vec!["+a", "+b"]);
            assert_eq!(render(&of("a", "")), vec!["-a"]);
        }

        #[test]
        fn a_huge_change_is_not_aligned() {
            let old = (0..500)
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join("\n");
            let d = of(&old, "x");
            assert_eq!(d.len(), MAX_LINES + 1);
            assert_eq!(d.last().unwrap().kind, '+');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(k: &str) -> Item {
        Item::Note {
            key: k.into(),
            text: k.into(),
        }
    }

    #[test]
    fn only_what_changed_is_sent() {
        let a = vec![note("1"), note("2")];
        assert_eq!(first_change(&a, &a), None);
        assert_eq!(
            first_change(&a, &[note("1"), note("2"), note("3")]),
            Some(2)
        );
        assert_eq!(first_change(&a, &[note("1"), note("x")]), Some(1));
        // A rewind that removed the tail.
        assert_eq!(first_change(&a, &[note("1")]), Some(1));
        assert_eq!(first_change(&a, &[]), Some(0));
    }

    #[test]
    fn take_counts_characters_not_bytes() {
        assert_eq!(take("中文字", 2), "中文");
        assert_eq!(take("ab", 5), "ab");
    }
}
