//! Window tags: names the person puts on a tmux window ("follow up",
//! "daily") so a window worth coming back to stands apart from one that can
//! be closed when it is done.
//!
//! Two halves, kept in two places on purpose:
//!
//! - **Which tags there are** — each one's id, name and colour — lives in
//!   `~/.config/attache-tags.toml`, a file the person can read, edit and keep
//!   in their dotfiles, written the way `projects.rs` writes its file: only
//!   the lines this program knows are changed, every comment and unknown key
//!   stays byte for byte.
//!
//!   ```toml
//!   [[tag]]
//!   id = "3f9a1c0e"
//!   name = "Follow up"
//!   color = "orange"
//!   ```
//!
//! - **Which window carries which tag** is the window's own tmux option,
//!   `@attache_tags`, holding ids separated by commas (`3f9a1c0e,77b2d410`).
//!   It is tmux's, so it goes when the window goes, and every client reads
//!   it the same way. Only ids are ever in it: a client sets it with
//!   `set-option -w -t @N @attache_tags <ids>`, and an id cannot carry a
//!   quote, a space or a comma, so no name ever reaches a tmux command line.
//!
//! Every change to the list also sets the global option `@attache_tags_rev`
//! on the default tmux server to a new value, so a client that subscribes to
//! it hears that the list changed instead of asking again on a timer.

use crate::agents::tidy_name;
use crate::fsutil::{safe_id, write_atomic, Lock};
use crate::input::decode;
use crate::projects::{encode_string, new_id, parse_blocks_of, Block};
use crate::{paths, tmux};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

const HEADER: &str = "[[tag]]";
const KNOWN: [&str; 3] = ["id", "name", "color"];
/// The longest name kept, in characters. A tag is drawn as a small chip
/// beside a window's name in a narrow rail.
const NAME_MAX: usize = 32;
/// The window option that holds a window's tag ids.
pub const WINDOW_OPTION: &str = "@attache_tags";
/// The global option every change to the list sets anew.
pub const REV_OPTION: &str = "@attache_tags_rev";

/// The colours a tag can have, by name, so every client draws the same
/// one from its own palette. Anything else written in the file reads as
/// the first.
pub const COLORS: [&str; 9] =
    ["gray", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"];

#[derive(Clone, Debug, PartialEq)]
pub struct Tag {
    pub id: String,
    pub name: String,
    pub color: String,
}

impl Tag {
    fn to_json(&self) -> Value {
        json!({ "id": self.id, "name": self.name, "color": self.color })
    }
}

/// `None` for a block with no name, or one written in a way this program
/// does not read: that block is the person's alone, never listed and so
/// never edited or removed from a client.
fn tag_of(block: &Block) -> Option<Tag> {
    let name = tidy_name(&block.text("name"));
    if block.unreadable || name.is_empty() {
        return None;
    }
    let color = block.text("color");
    let color = if COLORS.contains(&color.as_str()) { color } else { COLORS[0].to_owned() };
    let id = match block.get("id") {
        Some(k) if safe_id(&k.value) => k.value.clone(),
        _ => derived_id(&name),
    };
    Some(Tag { id, name, color })
}

/// The id of a block written by hand without one: the same until its name
/// is edited, which is all a client needs between listing and acting. A
/// tag put on a window under this id is lost when the first save writes a
/// real one only if the name changed in between.
fn derived_id(name: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in name.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("x{h:016x}")
}

fn blocks(lines: &[&str]) -> Vec<Block> {
    parse_blocks_of(lines, HEADER, &KNOWN)
}

pub fn list(text: &str) -> Vec<Tag> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<Tag> = Vec::new();
    for tag in blocks(&lines).iter().filter_map(tag_of) {
        // Two blocks with one id: the first is the tag, as a reader of the
        // window option would have to pick one anyway.
        if !out.iter().any(|t| t.id == tag.id) {
            out.push(tag);
        }
    }
    out
}

const PREAMBLE: &str = "# Attaché window tags: a name and a colour each.\n#\n# Yours to edit. Attaché rewrites only the lines it recognises, so comments\n# and anything else you put here survive. A window keeps the ids of its\n# tags in its tmux option @attache_tags.\n";

/// The file with `tag` saved, and the tag as it now is; `Err` with the
/// reason when it cannot be. With `existing`, the block that has that id
/// is changed in place and keeps the id written in it; otherwise a new
/// block goes at the end with `tag.id`.
pub fn save(text: &str, existing: Option<&str>, tag: &Tag) -> Result<(String, Tag), String> {
    let mut tag = tag.clone();
    let lines: Vec<&str> = text.split('\n').collect();
    let all = blocks(&lines);
    let block = match existing {
        Some(id) => Some(
            all.iter()
                .find(|b| tag_of(b).is_some_and(|t| t.id == id))
                .ok_or_else(|| "there is no such tag".to_owned())?,
        ),
        None => None,
    };
    let current = block.and_then(tag_of).map(|t| t.id);
    let taken = list(text).into_iter().any(|t| {
        Some(&t.id) != current.as_ref() && t.name.to_lowercase() == tag.name.to_lowercase()
    });
    if taken {
        return Err(format!("there is already a tag called {}", tag.name));
    }
    if let Some(written) = block.and_then(|b| b.get("id")).filter(|k| safe_id(&k.value)) {
        tag.id = written.value.clone();
    } else if let Some(derived) = current {
        // A hand-written block keeps the id it was listed under, so the
        // windows already carrying it keep their tag.
        tag.id = derived;
    }
    let fields = [("id", &tag.id), ("name", &tag.name), ("color", &tag.color)];
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
        return Ok((out, tag));
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
    out.splice(block.end..block.end, missing);
    Ok((out.join("\n"), tag))
}

/// The file without the block that has `id`; `None` when there is none.
pub fn remove(text: &str, id: &str) -> Option<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let all = blocks(&lines);
    let block = all.iter().find(|b| tag_of(b).is_some_and(|t| t.id == id))?;
    let mut out: Vec<&str> = lines.clone();
    out.drain(block.header..block.end);
    let at = block.header;
    if at > 0 && out[at - 1].trim().is_empty() && out.get(at).is_none_or(|l| l.trim().is_empty()) {
        out.remove(at - 1);
    }
    Some(out.join("\n"))
}

/// A window option's ids with `id` taken out; `None` when it was not there.
pub fn without(value: &str, id: &str) -> Option<String> {
    let ids: Vec<&str> = value.split(',').filter(|s| !s.is_empty()).collect();
    if !ids.contains(&id) {
        return None;
    }
    Some(ids.into_iter().filter(|s| *s != id).collect::<Vec<_>>().join(","))
}

fn file() -> PathBuf {
    let path = paths::home().join(".config/attache-tags.toml");
    // A dotfiles setup keeps the real file elsewhere and a link here; a
    // rename over the link would leave the dotfiles copy stale.
    fs::canonicalize(&path).unwrap_or(path)
}

fn read() -> Result<String, String> {
    match fs::read(file()) {
        Ok(bytes) => String::from_utf8(bytes).map_err(|_| "the tags file is not UTF-8 text".to_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read the tags file: {e}")),
    }
}

/// Reads the file, lets `change` make the new one, and writes it, all under
/// the lock so two clients saving at once both land.
fn update<T>(change: impl FnOnce(&str) -> Result<(String, T), String>) -> Result<T, String> {
    let lock = Lock::acquire(&paths::state_dir().join("tags.lock"), Duration::from_secs(2))
        .map_err(|e| format!("cannot lock the tags file: {e}"))?;
    if lock.is_none() {
        return Err("another change to the tags file is still running".into());
    }
    let (text, value) = change(&read()?)?;
    write_atomic(&file(), text.as_bytes()).map_err(|e| format!("cannot write the tags file: {e}"))?;
    Ok(value)
}

/// Tells subscribed clients the list changed. A host with no tmux server
/// running has no client to tell, so a failure here is not one.
fn announce() {
    // Milliseconds, so two changes within one second still differ: a
    // subscription only speaks when the value does.
    let rev = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default()
        .to_string();
    let _ = tmux::run(&["set-option", "-g", REV_OPTION, &rev]);
}

/// Takes `id` off every window on the default tmux server that carries it;
/// how many there were.
fn strip_windows(id: &str) -> usize {
    let format = format!("#{{window_id}}\t#{{{WINDOW_OPTION}}}");
    let mut changed = 0;
    for line in tmux::lines(&["list-windows", "-a", "-F", &format]) {
        let Some((window, value)) = line.split_once('\t') else { continue };
        if !is_window_id(window) {
            continue;
        }
        let Some(rest) = without(value, id) else { continue };
        let ok = if rest.is_empty() {
            tmux::run(&["set-option", "-wu", "-t", window, WINDOW_OPTION])
        } else {
            tmux::run(&["set-option", "-w", "-t", window, WINDOW_OPTION, &rest])
        };
        if ok.is_some_and(|o| o.status.success()) {
            changed += 1;
        }
    }
    changed
}

fn is_window_id(s: &str) -> bool {
    s.strip_prefix('@').is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

fn fail(what: &str, why: &str) -> i32 {
    println!("{}", json!({ what: false, "why": why }));
    1
}

fn arg<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let at = args.iter().position(|a| a == flag)?;
    args.get(at + 1).map(String::as_str)
}

/// `attache-cli tags`: one line, `{"tags":[{"id","name","color"},…],
/// "colors":[…]}`, the tags in the file's order and the colour names a
/// client may offer.
pub fn run_list(_args: &[String]) -> i32 {
    match read() {
        Ok(text) => {
            let tags: Vec<Value> = list(&text).iter().map(Tag::to_json).collect();
            println!("{}", json!({ "tags": tags, "colors": COLORS }));
            0
        }
        Err(why) => {
            eprintln!("attache-cli tags: {why}");
            1
        }
    }
}

pub fn run(args: &[String]) -> i32 {
    let usage = || {
        eprintln!("Usage:\n  attache-cli tags\n  attache-cli tag save [--id <id>] --name <base64> --color <colour>\n  attache-cli tag remove <id>");
        2
    };
    let Some((verb, rest)) = args.split_first() else {
        return usage();
    };
    match (verb.as_str(), rest) {
        ("save", rest) => run_save(rest).unwrap_or_else(usage),
        ("remove", [id]) if safe_id(id) => {
            match update(|text| remove(text, id).map(|t| (t, ())).ok_or_else(|| "there is no such tag".to_owned())) {
                Ok(()) => {
                    let windows = strip_windows(id);
                    announce();
                    println!("{}", json!({ "removed": true, "id": id, "windows": windows }));
                    0
                }
                Err(why) => fail("removed", &why),
            }
        }
        _ => usage(),
    }
}

/// Prints `{"saved":true,"id","name","color"}` with the tag as kept, or
/// `{"saved":false,"why"}`. `None` when the arguments are not a save.
fn run_save(args: &[String]) -> Option<i32> {
    let existing = arg(args, "--id");
    if existing.is_some_and(|id| !safe_id(id)) {
        return None;
    }
    let name = String::from_utf8(decode(arg(args, "--name")?)?).ok()?;
    let name: String = tidy_name(&name).chars().take(NAME_MAX).collect();
    let color = arg(args, "--color")?;
    if name.is_empty() {
        return Some(fail("saved", "a tag needs a name"));
    }
    if !COLORS.contains(&color) {
        return Some(fail("saved", &format!("{color} is not one of the colours")));
    }
    let tag = Tag { id: new_id(), name, color: color.to_owned() };
    Some(match update(|text| save(text, existing, &tag)) {
        Ok(saved) => {
            announce();
            let mut answer = saved.to_json();
            answer["saved"] = json!(true);
            println!("{answer}");
            0
        }
        Err(why) => fail("saved", &why),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(id: &str, name: &str, color: &str) -> Tag {
        Tag { id: id.into(), name: name.into(), color: color.into() }
    }

    #[test]
    fn a_first_save_writes_the_preamble_and_one_block() {
        let (text, saved) = save("", None, &tag("aa11", "Follow up", "orange")).unwrap();
        assert!(text.starts_with(PREAMBLE));
        assert!(text.ends_with("[[tag]]\nid = \"aa11\"\nname = \"Follow up\"\ncolor = \"orange\"\n"));
        assert_eq!(saved, tag("aa11", "Follow up", "orange"));
        assert_eq!(list(&text), vec![tag("aa11", "Follow up", "orange")]);
    }

    #[test]
    fn an_edit_changes_only_the_values_and_keeps_comments() {
        let text = "# mine\n[[tag]]\nid = \"aa11\" # keep\nname = \"Daily\"\ncolor = \"blue\"\nextra = 3\n\n[other]\nx = 1\n";
        let (out, saved) = save(text, Some("aa11"), &tag("zz99", "Every day", "green")).unwrap();
        assert_eq!(
            out,
            "# mine\n[[tag]]\nid = \"aa11\" # keep\nname = \"Every day\"\ncolor = \"green\"\nextra = 3\n\n[other]\nx = 1\n"
        );
        assert_eq!(saved.id, "aa11");
    }

    #[test]
    fn a_hand_written_block_keeps_its_listed_id_through_a_save() {
        let text = "[[tag]]\nname = \"Daily\"\n";
        let listed = list(text)[0].id.clone();
        assert!(listed.starts_with('x'));
        let (out, saved) = save(text, Some(&listed), &tag("new1", "Daily", "red")).unwrap();
        assert_eq!(saved.id, listed);
        assert_eq!(list(&out), vec![tag(&listed, "Daily", "red")]);
    }

    #[test]
    fn two_tags_cannot_share_a_name() {
        let (text, _) = save("", None, &tag("aa11", "Daily", "blue")).unwrap();
        assert!(save(&text, None, &tag("bb22", "daily", "red")).is_err());
        // Saving a tag under its own name is not a clash.
        assert!(save(&text, Some("aa11"), &tag("x", "Daily", "red")).is_ok());
    }

    #[test]
    fn an_unknown_colour_reads_as_gray_and_a_nameless_block_is_not_listed() {
        let text = "[[tag]]\nid = \"a\"\nname = \"A\"\ncolor = \"mauve\"\n\n[[tag]]\nid = \"b\"\n";
        assert_eq!(list(text), vec![tag("a", "A", "gray")]);
    }

    #[test]
    fn a_block_with_an_unreadable_known_key_is_left_alone() {
        let text = "[[tag]]\nid = \"a\"\nname = 3\n";
        assert!(list(text).is_empty());
        assert!(remove(text, "a").is_none());
    }

    #[test]
    fn remove_takes_out_the_block_and_its_blank_line() {
        let text = "# top\n\n[[tag]]\nid = \"a\"\nname = \"A\"\n\n[[tag]]\nid = \"b\"\nname = \"B\"\n";
        assert_eq!(remove(text, "b").unwrap(), "# top\n\n[[tag]]\nid = \"a\"\nname = \"A\"\n");
        assert!(remove(text, "c").is_none());
    }

    #[test]
    fn without_takes_one_id_out_of_a_window_option() {
        assert_eq!(without("a,b,c", "b").as_deref(), Some("a,c"));
        assert_eq!(without("b", "b").as_deref(), Some(""));
        assert_eq!(without("a,c", "b"), None);
        assert_eq!(without("", "b"), None);
        // `ab` is not `a`.
        assert_eq!(without("ab", "a"), None);
    }

    #[test]
    fn a_header_inside_a_multiline_string_is_not_a_tag() {
        let text = "note = \"\"\"\n[[tag]]\nname = \"fake\"\n\"\"\"\n";
        assert!(list(text).is_empty());
    }
}
