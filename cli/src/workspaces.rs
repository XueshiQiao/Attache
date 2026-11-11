//! Saved workspaces: a folder and the command to start in it, kept on the
//! host so a window can be closed and made again with one click from either
//! client.
//!
//! They live in `~/.config/attache-workspaces.toml`, a file the person can
//! read, edit and keep in their dotfiles:
//!
//! ```toml
//! [[workspace]]
//! id = "3f9a1c0e"
//! name = "PastePaw"
//! path = "~/Code/PastePawX"
//! command = "cyolo"
//! ```
//!
//! This program changes only the lines it has to: a save rewrites the value
//! of the keys it knows inside the one block, a remove takes out that block's
//! header and key lines, and every comment, unknown key and other table
//! stays byte for byte. A block written by hand needs no `id`; it gets one
//! worked out from its contents until the first save writes a real one.
//!
//! The folder and the command are the person's own text and never leave this
//! host as anything but data: a client names a workspace by id, and `open`
//! hands the text to tmux as separate arguments, never through a shell of
//! this program's making.

use crate::agents::{self, tidy_name, tmux_literal};
use crate::fsutil::{safe_id, write_atomic, Lock};
use crate::host::RealHost;
use crate::input::decode;
use crate::{paths, tmux};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

const HEADER: &str = "[[workspace]]";
/// The longest command kept, in characters.
const COMMAND_MAX: usize = 4000;

#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub path: String,
    pub command: String,
}

impl Workspace {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "path": self.path,
            "command": self.command,
            "exists": is_full_path(&self.path) && expand(&self.path).is_dir(),
        })
    }
}

/// One `key = "value"` line inside a block.
struct KeyLine {
    key: String,
    line: usize,
    /// Byte range of the value, quotes included, within the line.
    span: (usize, usize),
    value: String,
}

struct Block {
    header: usize,
    /// One past the block's last key line (the header's own, if it has none).
    end: usize,
    keys: Vec<KeyLine>,
    /// One of the four keys this program knows is written in a way it does
    /// not read: a multi-line string, a number, the same key twice. The
    /// block is then the person's alone — not listed, so never edited or
    /// removed from a client. Listing it with that key taken for absent
    /// would run a plain shell where a command was written, and a save
    /// would add the key a second time, which is not TOML any more.
    unreadable: bool,
}

const KNOWN: [&str; 4] = ["id", "name", "path", "command"];

impl Block {
    fn get(&self, key: &str) -> Option<&KeyLine> {
        self.keys.iter().find(|k| k.key == key)
    }

    fn text(&self, key: &str) -> String {
        self.get(key).map(|k| k.value.clone()).unwrap_or_default()
    }

    /// `None` for a block with no folder: there is nothing to open.
    fn workspace(&self) -> Option<Workspace> {
        let path = self.text("path");
        if self.unreadable || path.trim().is_empty() {
            return None;
        }
        let command = self.text("command");
        let mut name = self.text("name");
        if name.trim().is_empty() {
            name = path.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_owned();
            if name.is_empty() {
                name = path.clone();
            }
        }
        let id = match self.get("id") {
            Some(k) if safe_id(&k.value) => k.value.clone(),
            _ => derived_id(&name, &path, &command),
        };
        Some(Workspace { id, name, path, command })
    }
}

/// The id of a block that has none written: the same until the block is
/// edited, which is all a client needs between listing and acting.
fn derived_id(name: &str, path: &str, command: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in [name, path, command].join("\0").bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("x{h:016x}")
}

/// Reads a TOML basic (`"…"`) or literal (`'…'`) string at the start of
/// `s`: the text and how many bytes it took. Multi-line strings are not
/// read; such a key is left alone as one this program does not know.
fn parse_string(s: &str) -> Option<(String, usize)> {
    if s.starts_with("\"\"\"") || s.starts_with("'''") {
        return None;
    }
    let mut chars = s.char_indices();
    match chars.next()?.1 {
        '\'' => {
            let end = s[1..].find('\'')?;
            Some((s[1..1 + end].to_owned(), end + 2))
        }
        '"' => {
            let mut out = String::new();
            while let Some((i, c)) = chars.next() {
                match c {
                    '"' => return Some((out, i + 1)),
                    '\\' => match chars.next()?.1 {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        'n' => out.push('\n'),
                        't' => out.push('\t'),
                        'r' => out.push('\r'),
                        'b' => out.push('\u{8}'),
                        'f' => out.push('\u{c}'),
                        e @ ('u' | 'U') => {
                            let n = if e == 'u' { 4 } else { 8 };
                            let hex: String = chars.by_ref().take(n).map(|(_, c)| c).collect();
                            if hex.len() != n {
                                return None;
                            }
                            out.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
                        }
                        _ => return None,
                    },
                    c => out.push(c),
                }
            }
            None
        }
        _ => None,
    }
}

fn encode_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A line with its comment taken off, for telling headers apart. Only used
/// on lines that start with `[`, where a `#` cannot be inside a string.
fn bare(line: &str) -> &str {
    line.split('#').next().unwrap_or("").trim()
}

/// Where a multi-line string that opens in `value` (the text after `=`)
/// closes: `Some(None)` on the same line, `Some(Some(delimiter))` on a later
/// one, `None` when `value` opens no such string.
fn opens_multiline(value: &str) -> Option<Option<&'static str>> {
    let delimiter = if value.starts_with("\"\"\"") {
        "\"\"\""
    } else if value.starts_with("'''") {
        "'''"
    } else {
        return None;
    };
    Some((!value[3..].contains(delimiter)).then_some(delimiter))
}

fn parse_blocks(lines: &[&str]) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut inside = false;
    // The delimiter a multi-line string is waiting for. Its lines are
    // nobody's headers or keys, whatever they look like, in any table.
    let mut closing: Option<&'static str> = None;
    for (i, raw) in lines.iter().enumerate() {
        if let Some(delimiter) = closing {
            if raw.contains(delimiter) {
                closing = None;
            }
            if inside {
                blocks.last_mut().expect("inside a block").end = i + 1;
            }
            continue;
        }
        let line = raw.trim_start();
        if line.starts_with('[') {
            inside = bare(line) == HEADER;
            if inside {
                blocks.push(Block { header: i, end: i + 1, keys: Vec::new(), unreadable: false });
            }
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let indent = raw.len() - line.len();
        let key_len = line
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-'))
            .unwrap_or(line.len());
        let key = &line[..key_len];
        let after_key = line[key_len..].trim_start();
        let value_text = after_key.strip_prefix('=').map(str::trim_start);
        if let Some(Some(delimiter)) = value_text.and_then(opens_multiline) {
            closing = Some(delimiter);
        }
        if !inside {
            continue;
        }
        let block = blocks.last_mut().expect("inside a block");
        // Any line that is not blank or a comment belongs to the block, read
        // or not: a remove takes it out with the rest.
        block.end = i + 1;
        let Some(value_text) = value_text.filter(|_| key_len > 0) else {
            continue;
        };
        let start = indent + (line.len() - value_text.len());
        let read = parse_string(value_text).filter(|(_, used)| {
            let rest = value_text[*used..].trim();
            rest.is_empty() || rest.starts_with('#')
        });
        let Some((value, used)) = read else {
            block.unreadable |= KNOWN.contains(&key);
            continue;
        };
        // A key written twice is not TOML; which one a reader takes is
        // anyone's guess, so the block is left alone too.
        block.unreadable |= KNOWN.contains(&key) && block.keys.iter().any(|k| k.key == key);
        block.keys.push(KeyLine {
            key: key.to_owned(),
            line: i,
            span: (start, start + used),
            value,
        });
    }
    blocks
}

pub fn list(text: &str) -> Vec<Workspace> {
    let lines: Vec<&str> = text.split('\n').collect();
    parse_blocks(&lines).iter().filter_map(Block::workspace).collect()
}

const PREAMBLE: &str = "# Attaché workspaces: a folder and the command to start in it.\n#\n# Yours to edit. Attaché rewrites only the lines it recognises, so comments\n# and anything else you put here survive.\n";

/// The file with `ws` saved, and the workspace as it now is. With
/// `existing`, the block that has that id is changed in place and keeps the
/// id written in it; `ws.id` is used only for a block that had none, and
/// for a new block, which goes at the end. `None` when `existing` names no
/// block.
pub fn save(text: &str, existing: Option<&str>, ws: &Workspace) -> Option<(String, Workspace)> {
    let mut ws = ws.clone();
    let lines: Vec<&str> = text.split('\n').collect();
    let blocks = parse_blocks(&lines);
    let block = match existing {
        Some(id) => Some(blocks.iter().find(|b| b.workspace().is_some_and(|w| w.id == id))?),
        None => None,
    };
    if let Some(written) = block.and_then(|b| b.get("id")).filter(|k| safe_id(&k.value)) {
        ws.id = written.value.clone();
    }
    let fields = [
        ("id", &ws.id),
        ("name", &ws.name),
        ("path", &ws.path),
        ("command", &ws.command),
    ];
    let Some(block) = block else {
        let mut out = if text.trim().is_empty() { PREAMBLE.to_owned() } else { text.to_owned() };
        if !out.ends_with('\n') {
            out.push('\n');
        }
        out.push('\n');
        out.push_str(HEADER);
        out.push('\n');
        for (key, value) in fields {
            out.push_str(&format!("{key} = {}\n", encode_string(value)));
        }
        return Some((out, ws));
    };
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_owned()).collect();
    let mut missing = Vec::new();
    for (key, value) in fields {
        match block.get(key) {
            Some(k) => {
                let line = lines[k.line];
                out[k.line] = format!("{}{}{}", &line[..k.span.0], encode_string(value), &line[k.span.1..]);
            }
            None => missing.push(format!("{key} = {}", encode_string(value))),
        }
    }
    // `id` is first in `fields`, so a block that had none gets it at the top
    // of what is added.
    out.splice(block.end..block.end, missing);
    Some((out.join("\n"), ws))
}

/// The file without the block that has `id`; `None` when there is none.
pub fn remove(text: &str, id: &str) -> Option<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let blocks = parse_blocks(&lines);
    let block = blocks.iter().find(|b| b.workspace().is_some_and(|w| w.id == id))?;
    let mut out: Vec<&str> = lines.clone();
    out.drain(block.header..block.end);
    // The blank line that separated the block from the one before it.
    let at = block.header;
    if at > 0 && out[at - 1].trim().is_empty() && out.get(at).is_none_or(|l| l.trim().is_empty()) {
        out.remove(at - 1);
    }
    Some(out.join("\n"))
}

fn file() -> PathBuf {
    let path = paths::home().join(".config/attache-workspaces.toml");
    // A dotfiles setup keeps the real file elsewhere and a link here; a
    // rename over the link would leave the dotfiles copy stale.
    fs::canonicalize(&path).unwrap_or(path)
}

fn read() -> Result<String, String> {
    match fs::read(file()) {
        Ok(bytes) => String::from_utf8(bytes).map_err(|_| "the workspaces file is not UTF-8 text".to_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read the workspaces file: {e}")),
    }
}

/// Reads the file, lets `change` make the new one, and writes it, all under
/// the lock so two clients saving at once both land.
fn update<T>(change: impl FnOnce(&str) -> Result<(String, T), String>) -> Result<T, String> {
    let lock = Lock::acquire(&paths::state_dir().join("workspaces.lock"), Duration::from_secs(2))
        .map_err(|e| format!("cannot lock the workspaces file: {e}"))?;
    if lock.is_none() {
        return Err("another change to the workspaces file is still running".into());
    }
    let (text, value) = change(&read()?)?;
    write_atomic(&file(), text.as_bytes()).map_err(|e| format!("cannot write the workspaces file: {e}"))?;
    Ok(value)
}

/// `~` and `~/…` are the home folder of whoever runs this, so one file can
/// be shared between hosts whose home folders differ.
fn expand(path: &str) -> PathBuf {
    if path == "~" {
        paths::home()
    } else if let Some(rest) = path.strip_prefix("~/") {
        paths::home().join(rest)
    } else {
        PathBuf::from(path)
    }
}

/// A path that means the same folder whoever resolves it. A relative one,
/// which only a hand-written block can hold, would be checked against this
/// process's folder and then opened against the session's.
fn is_full_path(path: &str) -> bool {
    path.starts_with('/') || path == "~" || path.starts_with("~/")
}

fn new_id() -> String {
    let mut bytes = [0u8; 4];
    let random = fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))
        .is_ok();
    if !random {
        let n = agents::now() as u32 ^ std::process::id().rotate_left(16);
        bytes = n.to_be_bytes();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn fail(what: &str, why: &str) -> i32 {
    println!("{}", json!({ what: false, "why": why }));
    1
}

/// The value after `flag`, base64-decoded into text.
fn text_arg(args: &[String], flag: &str) -> Option<String> {
    let at = args.iter().position(|a| a == flag)?;
    String::from_utf8(decode(args.get(at + 1)?)?).ok()
}

fn plain_arg<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let at = args.iter().position(|a| a == flag)?;
    args.get(at + 1).map(String::as_str)
}

/// `attache-cli workspaces`: one JSON line per saved workspace, in the
/// file's order: `id`, `name`, `path`, `command`, and `exists` (whether the
/// folder is there now).
pub fn run_list(_args: &[String]) -> i32 {
    match read() {
        Ok(text) => {
            for ws in list(&text) {
                println!("{}", ws.to_json());
            }
            0
        }
        Err(why) => {
            eprintln!("attache-cli workspaces: {why}");
            1
        }
    }
}

pub fn run(args: &[String]) -> i32 {
    let usage = || {
        eprintln!("Usage:\n  attache-cli workspace save [--id <id>] --name <base64> --path <base64> --command <base64>\n  attache-cli workspace remove <id>\n  attache-cli workspace open <id> --session <$N>\n  attache-cli workspace draft <@window>");
        2
    };
    let Some((verb, rest)) = args.split_first() else {
        return usage();
    };
    match (verb.as_str(), rest) {
        ("save", rest) => run_save(rest).unwrap_or_else(usage),
        ("remove", [id]) if safe_id(id) => match update(|text| {
            remove(text, id).map(|t| (t, ())).ok_or_else(|| "there is no such workspace".to_owned())
        }) {
            Ok(()) => {
                println!("{}", json!({ "removed": true, "id": id }));
                0
            }
            Err(why) => fail("removed", &why),
        },
        ("open", [id, flag, session]) if safe_id(id) && flag == "--session" && is_id(session, '$') => {
            run_open(id, session)
        }
        ("draft", [window]) if is_id(window, '@') => run_draft(window),
        _ => usage(),
    }
}

/// `$3`, `@12`: a tmux id, which cannot carry anything but digits.
fn is_id(s: &str, sigil: char) -> bool {
    s.strip_prefix(sigil)
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// Prints `{"saved":true,"id",…}` with the workspace as kept, or
/// `{"saved":false,"why"}`. `None` when the arguments are not a save.
fn run_save(args: &[String]) -> Option<i32> {
    let existing = plain_arg(args, "--id");
    if existing.is_some_and(|id| !safe_id(id)) {
        return None;
    }
    let name = tidy_name(&text_arg(args, "--name")?);
    let path = text_arg(args, "--path")?.trim().to_owned();
    let command = text_arg(args, "--command")?.trim().to_owned();
    if name.is_empty() {
        return Some(fail("saved", "the name is empty"));
    }
    if !is_full_path(&path) || path.chars().any(char::is_control) {
        return Some(fail("saved", "the folder has to be a full path, or start with ~/"));
    }
    if command.chars().any(char::is_control) || command.chars().count() > COMMAND_MAX {
        return Some(fail("saved", "the command has to be one line"));
    }
    let saved = update(|text| {
        let ws = Workspace { id: new_id(), name, path, command };
        save(text, existing, &ws).ok_or_else(|| "there is no such workspace".to_owned())
    });
    Some(match saved {
        Ok(ws) => {
            let mut v = ws.to_json();
            v["saved"] = json!(true);
            println!("{v}");
            0
        }
        Err(why) => fail("saved", &why),
    })
}

/// One argument of a shell command line, quoted so the shell reads it back
/// as exactly this text.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// [`sh_quote`] for the shell that will read it. fish is the one shell in
/// use that is not POSIX here: inside single quotes it reads `\\` as one
/// backslash and `\'` as a quote (fish's documentation, "Quotes"; not run
/// here, there was no fish on the machine this was written on), so a
/// backslash is doubled and a quote escaped in place.
fn quote_for(shell: &str, s: &str) -> String {
    if shell.rsplit('/').next() == Some("fish") {
        format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'"))
    } else {
        sh_quote(s)
    }
}

/// The shell tmux starts in a new pane.
fn default_shell() -> String {
    tmux::lines(&["show-options", "-gv", "default-shell"])
        .into_iter()
        .next()
        .filter(|s| s.starts_with('/'))
        .or_else(|| std::env::var("SHELL").ok().filter(|s| s.starts_with('/')))
        .unwrap_or_else(|| "/bin/sh".into())
}

/// `attache-cli workspace open <id> --session <$N>`: a new window in that
/// session, in the workspace's folder, named after it and selected, running
/// its command. Prints `{"opened":true,"window","pane"}` or
/// `{"opened":false,"why"}`. Opening the same workspace again makes another
/// window: several of one are an ordinary thing to want.
///
/// The command runs in the person's own shell, started the way tmux starts
/// it but with the command to run first: `<shell> -l -i -c 'eval <command>;
/// exec <shell> -l'`. Interactive, because `cyolo` is an alias and only an
/// interactive shell has read the file that defines it (measured 2026-11-11
/// on zsh 5.9 and bash 3.2: the alias ran). `eval`, so a command with a
/// mistake in it prints the shell's error and leaves a prompt, where the
/// same text put straight into `-c` would not parse and the window would be
/// gone before anything could be read. The `exec` afterwards is what leaves
/// a shell in the window when the command ends, as if it had been typed.
///
/// tmux expands `-c` and `-n` as formats (measured on 3.6a: a folder named
/// `h#{pane_id}x` opened the home folder instead), so every `#` in them is
/// doubled. The command is a separate argument, which tmux does not expand.
fn run_open(id: &str, session: &str) -> i32 {
    let ws = match read() {
        Ok(text) => list(&text).into_iter().find(|w| w.id == id),
        Err(why) => return fail("opened", &why),
    };
    let Some(ws) = ws else {
        return fail("opened", "there is no such workspace");
    };
    if !is_full_path(&ws.path) {
        return fail("opened", "the folder has to be a full path, or start with ~/");
    }
    let dir = expand(&ws.path);
    if !dir.is_dir() {
        return fail("opened", &format!("the folder is not there: {}", dir.display()));
    }
    let dir = tmux_literal(&dir.to_string_lossy());
    let name = tmux_literal(&tidy_name(&ws.name));
    let target = format!("{session}:");
    let shell = default_shell();
    let script = format!("eval {}; exec {} -l", quote_for(&shell, &ws.command), quote_for(&shell, &shell));
    let mut args = vec![
        "new-window", "-P", "-F", "#{window_id}\t#{pane_id}", "-t", &target, "-c", &dir, "-n", &name,
    ];
    if !ws.command.trim().is_empty() {
        args.extend(["--", &shell, "-l", "-i", "-c", &script]);
    }
    let out = match tmux::command().args(&args).stderr(Stdio::piped()).output() {
        Ok(out) => out,
        Err(e) => return fail("opened", &format!("cannot run tmux: {e}")),
    };
    if !out.status.success() {
        return fail("opened", String::from_utf8_lossy(&out.stderr).trim());
    }
    let made = String::from_utf8_lossy(&out.stdout);
    let mut ids = made.trim().split('\t');
    println!(
        "{}",
        json!({ "opened": true, "id": ws.id, "window": ids.next(), "pane": ids.next() })
    );
    0
}

/// `attache-cli workspace draft <@window>`: what saving that window as a
/// workspace would start from, for a client to show and the person to edit:
/// `{"draft":true,"name","path","command"}`. The folder is the active
/// pane's; the command is how the agent in that pane was started, when
/// there is one, with any alias already spelled out, since the process
/// table holds what ran and not what was typed.
fn run_draft(window: &str) -> i32 {
    let line = tmux::lines(&[
        "display-message", "-p", "-t", window, "#{pane_id}\t#{pane_current_path}\t#{window_name}",
    ])
    .into_iter()
    .next()
    .unwrap_or_default();
    let f: Vec<&str> = line.splitn(3, '\t').collect();
    if f.len() != 3 || !f[0].starts_with('%') {
        return fail("draft", "there is no such window");
    }
    let command = agents::discover(&RealHost, Some(f[0]))
        .first()
        .map(|a| a.pid.and_then(|pid| started_as(pid, a.kind)).unwrap_or_else(|| a.kind.to_owned()))
        .unwrap_or_default();
    println!(
        "{}",
        json!({ "draft": true, "name": tidy_name(f[2]), "path": f[1], "command": command })
    );
    0
}

/// The command line of `pid`, when it is the agent's own program: `claude
/// --dangerously-skip-permissions`, not `node /usr/lib/…/cli.js`, which
/// names a file and says nothing a person would type.
fn started_as(pid: u32, kind: &str) -> Option<String> {
    let argv: Vec<String> = match fs::read(format!("/proc/{pid}/cmdline")) {
        Ok(bytes) => bytes
            .split(|b| *b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect(),
        // macOS: `ps` joins the arguments with spaces and that is all there
        // is to read; an argument with a space in it comes out unquoted.
        Err(_) => {
            let out = std::process::Command::new("ps")
                .args(["-o", "args=", "-p", &pid.to_string()])
                .stderr(Stdio::null())
                .output()
                .ok()?;
            String::from_utf8_lossy(&out.stdout).split_whitespace().map(str::to_owned).collect()
        }
    };
    let (program, rest) = argv.split_first()?;
    if program.rsplit('/').next() != Some(kind) {
        return None;
    }
    let plain = |a: &str| !a.is_empty() && a.chars().all(|c| c.is_ascii_alphanumeric() || "-_=./:,@%+".contains(c));
    let mut words = vec![kind.to_owned()];
    words.extend(rest.iter().map(|a| if plain(a) { a.clone() } else { sh_quote(a) }));
    Some(words.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws(id: &str, name: &str, path: &str, command: &str) -> Workspace {
        Workspace { id: id.into(), name: name.into(), path: path.into(), command: command.into() }
    }

    const HAND: &str = "# mine\ntheme = \"dark\"\n\n# the main one\n[[workspace]]\nname = 'PastePaw'   # literal\npath = \"~/Code/PastePawX\"\ncommand = \"cyolo\"\nretries = 3\n\n[other]\nname = \"not a workspace\"\n\n[[workspace]]  # second\nid = \"abcd1234\"\npath = \"/srv/a \\\"b\\\"\"\n";

    #[test]
    fn a_hand_written_file_reads() {
        let all = list(HAND);
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].name, "PastePaw");
        assert_eq!(all[0].path, "~/Code/PastePawX");
        assert_eq!(all[0].command, "cyolo");
        assert!(all[0].id.starts_with('x'));
        // No name: the folder's last part. No command: just a shell.
        assert_eq!(all[1], ws("abcd1234", "a \"b\"", "/srv/a \"b\"", ""));
    }

    #[test]
    fn a_new_one_goes_at_the_end_and_nothing_else_moves() {
        let (out, _) = save(HAND, None, &ws("11112222", "T \"q\"", "/tmp/x\\y", "claude -c")).unwrap();
        assert_eq!(
            out,
            format!("{HAND}\n[[workspace]]\nid = \"11112222\"\nname = \"T \\\"q\\\"\"\npath = \"/tmp/x\\\\y\"\ncommand = \"claude -c\"\n")
        );
        assert_eq!(list(&out)[2], ws("11112222", "T \"q\"", "/tmp/x\\y", "claude -c"));
    }

    #[test]
    fn the_first_one_makes_the_file() {
        let (out, _) = save("", None, &ws("11112222", "T", "/tmp", "")).unwrap();
        assert!(out.starts_with("# Attaché workspaces"));
        assert_eq!(list(&out), vec![ws("11112222", "T", "/tmp", "")]);
    }

    #[test]
    fn an_edit_changes_only_the_values_and_keeps_comments_and_unknown_keys() {
        let id = list(HAND)[0].id.clone();
        let (out, kept) = save(HAND, Some(&id), &ws("99990000", "Paw", "/p", "claude")).unwrap();
        assert_eq!(kept.id, "99990000");
        assert_eq!(
            out,
            HAND.replace("name = 'PastePaw'   # literal", "name = \"Paw\"   # literal")
                .replace("path = \"~/Code/PastePawX\"", "path = \"/p\"")
                .replace("command = \"cyolo\"\nretries = 3\n", "command = \"claude\"\nretries = 3\nid = \"99990000\"\n")
        );
        // The other table's `name` was not the block's.
        assert!(out.contains("[other]\nname = \"not a workspace\""));
        // Keys the block lacked are added to it, not to the end of the file.
        // The id written in a block is kept, whatever the caller brought.
        let (out, kept) = save(HAND, Some("abcd1234"), &ws("ffff0000", "A", "/srv/a", "x")).unwrap();
        assert_eq!(kept.id, "abcd1234");
        assert!(out.ends_with("id = \"abcd1234\"\npath = \"/srv/a\"\nname = \"A\"\ncommand = \"x\"\n"));
        assert!(save(HAND, Some("nope"), &ws("nope", "A", "/a", "")).is_none());
    }

    #[test]
    fn a_remove_takes_the_block_and_leaves_the_rest() {
        let id = list(HAND)[0].id.clone();
        assert_eq!(
            remove(HAND, &id).unwrap(),
            "# mine\ntheme = \"dark\"\n\n# the main one\n\n[other]\nname = \"not a workspace\"\n\n[[workspace]]  # second\nid = \"abcd1234\"\npath = \"/srv/a \\\"b\\\"\"\n"
        );
        assert_eq!(
            remove(HAND, "abcd1234").unwrap(),
            HAND.replace("\n[[workspace]]  # second\nid = \"abcd1234\"\npath = \"/srv/a \\\"b\\\"\"\n", "")
        );
        assert!(remove(HAND, "nope").is_none());
        // Saved then removed is the file as it was, plus nothing.
        let (added, _) = save(HAND, None, &ws("11112222", "T", "/tmp", "")).unwrap();
        assert_eq!(remove(&added, "11112222").unwrap(), HAND);
    }

    #[test]
    fn strings_survive_a_round_trip() {
        for s in ["", "plain", "it's", "a \"b\" \\ c", "中文 # not a comment", "tab\there"] {
            let enc = encode_string(s);
            assert_eq!(parse_string(&enc), Some((s.to_owned(), enc.len())), "{s}");
        }
        assert_eq!(parse_string("'a # b' # c"), Some(("a # b".into(), 7)));
        assert_eq!(parse_string("\"\"\"multi"), None);
        assert_eq!(parse_string("3"), None);
    }

    #[test]
    fn a_block_this_program_cannot_read_is_left_alone() {
        // A multi-line command with a line that looks like a header, a
        // number for an id, a key written twice: none is listed, so none can
        // be edited into two `command` keys or half removed.
        let odd = concat!(
            "[[workspace]]\nid = \"aaaa1111\"\npath = \"/a\"\ncommand = '''\nclaude\n[[workspace]]\npath = \"/inside\"\n'''\n\n",
            "[[workspace]]\nid = 123\npath = \"/b\"\n\n",
            "[[workspace]]\npath = \"/c\"\npath = \"/d\"\n\n",
            "[[workspace]]\nid = \"eeee5555\"\npath = \"/e\"\nnote = \"\"\"\n[other]\n\"\"\"\ncommand = \"x\"\n",
        );
        assert_eq!(list(odd), vec![ws("eeee5555", "e", "/e", "x")]);
        assert!(save(odd, Some("aaaa1111"), &ws("aaaa1111", "A", "/a", "x")).is_none());
        assert!(remove(odd, "aaaa1111").is_none());
        // The readable one goes whole, its unknown multi-line key with it.
        assert!(remove(odd, "eeee5555").unwrap().ends_with("path = \"/d\"\n"));
        // A new one still goes at the end, the rest untouched.
        let (out, _) = save(odd, None, &ws("ffff6666", "F", "/f", "")).unwrap();
        assert!(out.starts_with(odd) && list(&out).len() == 2);
        assert!(!is_full_path("Code/x") && is_full_path("~/x") && is_full_path("/x") && !is_full_path("~user/x"));
    }

    #[test]
    fn fish_reads_single_quotes_its_own_way() {
        assert_eq!(quote_for("/bin/zsh", r"a\b 'c'"), r"'a\b '\''c'\'''");
        assert_eq!(quote_for("/opt/homebrew/bin/fish", r"a\b 'c'"), r"'a\\b \'c\''");
    }

    #[test]
    fn a_command_is_quoted_for_the_shell_as_one_word() {
        assert_eq!(sh_quote("it's"), "'it'\\''s'");
        assert!(is_id("$12", '$') && !is_id("$", '$') && !is_id("$1;x", '$') && !is_id("@1", '$'));
    }
}
