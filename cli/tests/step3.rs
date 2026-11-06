//! `follow`, run as the phone runs it: a long-lived process whose stdout is
//! read line by line while the test writes to the transcript.

use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

struct Follower {
    child: Child,
    events: Receiver<Value>,
}

impl Follower {
    fn start(home: &Path, args: &[&str]) -> Follower {
        let mut child = Command::new(env!("CARGO_BIN_EXE_attache-cli"))
            .arg("follow")
            .args(args)
            .env_clear()
            .env("HOME", home)
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx
                    .send(serde_json::from_str::<Value>(&line).unwrap())
                    .is_err()
                {
                    break;
                }
            }
        });
        Follower { child, events: rx }
    }

    /// The next event matching `want`, skipping others, within 5 s.
    fn until(&self, want: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let e = self
                .events
                .recv_timeout(left)
                .expect("no such event in time");
            if want(&e) {
                return e;
            }
        }
    }

    fn next_of(&self, t: &str) -> Value {
        self.until(|e| e["t"] == t)
    }
}

impl Drop for Follower {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn append(path: &Path, lines: &[String]) {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    for l in lines {
        writeln!(f, "{l}").unwrap();
    }
}

fn user(uuid: &str, text: &str) -> String {
    json!({ "type": "user", "uuid": uuid, "message": { "role": "user", "content": text } })
        .to_string()
}

fn reply(uuid: &str, text: &str) -> String {
    json!({ "type": "assistant", "uuid": uuid, "message": { "model": "claude-opus-5-5", "content": [{ "type": "text", "text": text }],
            "usage": { "input_tokens": 10, "cache_read_input_tokens": 90_000, "cache_creation_input_tokens": 0 } } })
    .to_string()
}

fn tool_call(uuid: &str, id: &str) -> String {
    json!({ "type": "assistant", "uuid": uuid, "message": { "model": "claude-opus-5-5",
            "content": [{ "type": "tool_use", "id": id, "name": "Bash", "input": { "command": "ls" } }] } })
    .to_string()
}

fn tool_result(uuid: &str, id: &str, out: &str) -> String {
    json!({ "type": "user", "uuid": uuid, "message": { "content": [{ "type": "tool_result", "tool_use_id": id, "content": out }] } }).to_string()
}

fn transcript(home: &Path, session: &str) -> PathBuf {
    let p = home
        .join(".claude/projects/-w")
        .join(format!("{session}.jsonl"));
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    p
}

fn keys(items: &Value) -> Vec<String> {
    items
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["key"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn it_reads_then_sends_only_what_changed() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    append(&path, &[user("u1", "hi"), tool_call("a1", "t1")]);
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    let hello = f.next_of("hello");
    assert_eq!(
        (
            hello["protocol"].as_u64(),
            hello["start"].as_u64(),
            hello["earlier"].as_bool()
        ),
        (Some(1), Some(0), Some(false))
    );
    let first = f.next_of("items");
    assert_eq!(first["from"], 0);
    assert_eq!(keys(&first["items"]), vec!["u1", "a1-0"]);
    assert_eq!(first["items"][1]["result"], Value::Null);

    // The tool's result lands on its call: row 1 is sent again, nothing before it.
    append(&path, &[tool_result("u2", "t1", "README.md")]);
    let landed = f.next_of("items");
    assert_eq!(landed["from"], 1);
    assert_eq!(landed["items"][0]["result"], "README.md");

    // A new reply: only the new row.
    append(&path, &[reply("a2", "完成")]);
    let added = f.next_of("items");
    assert_eq!(
        (added["from"].as_u64(), keys(&added["items"])),
        (Some(2), vec!["a2-0".to_owned()])
    );
}

#[test]
fn a_line_written_in_two_pieces_is_read_once_whole() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    append(&path, &[user("u1", "hi")]);
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    f.next_of("items");
    // Cut in the middle of a character, as a write can be.
    let line = format!("{}\n", reply("a1", "一段很长的回答"));
    let bytes = line.as_bytes();
    let cut = line.find("很").unwrap() + 1;
    let mut file = OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(&bytes[..cut]).unwrap();
    file.flush().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    file.write_all(&bytes[cut..]).unwrap();
    let items = f.next_of("items");
    assert_eq!(items["items"][0]["text"], "一段很长的回答");
}

#[test]
fn a_file_that_does_not_exist_yet_is_waited_for() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "new");
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    f.next_of("waiting");
    append(&path, &[user("u1", "first message")]);
    f.next_of("hello");
    assert_eq!(keys(&f.next_of("items")["items"]), vec!["u1"]);
}

#[test]
fn a_conversation_handed_to_another_session_is_followed_there() {
    let home = tempfile::tempdir().unwrap();
    let old = transcript(home.path(), "old");
    let new = transcript(home.path(), "c94cb7d8-1e11-4a15-b95d-b432b56207bb");
    append(&old, &[user("u1", "before")]);
    let f = Follower::start(home.path(), &["claude", old.to_str().unwrap()]);
    f.next_of("items");
    // As 2.1.311 does it: the new file starts with copies, then goes on.
    append(&new, &[user("u1", "before"), reply("a1", "after")]);
    append(&old, &[json!({ "type": "continued-in", "continuedInSessionId": "c94cb7d8-1e11-4a15-b95d-b432b56207bb" }).to_string()]);
    let switched = f.next_of("switched");
    assert_eq!(switched["path"], new.to_str().unwrap());
    assert_eq!(f.next_of("hello")["path"], new.to_str().unwrap());
    assert_eq!(keys(&f.next_of("items")["items"]), vec!["u1", "a1-0"]);
    // And it keeps following the new file.
    append(&new, &[reply("a2", "more")]);
    assert_eq!(f.next_of("items")["from"], 2);
}

#[test]
fn earlier_history_is_a_new_follow_from_further_back() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    // Rows big enough that the first window cannot hold them all.
    let pad = "字".repeat(4000);
    let lines: Vec<String> = (0..400)
        .map(|i| reply(&format!("a{i}"), &format!("{i} {pad}")))
        .collect();
    append(&path, &lines);
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    let hello = f.next_of("hello");
    assert_eq!(hello["earlier"], true);
    let start = hello["start"].as_u64().unwrap();
    let first = keys(&f.next_of("items")["items"]);
    assert!(first.len() >= 60, "{}", first.len());
    assert_eq!(first.last().unwrap(), "a399-0");
    drop(f);

    let g = Follower::start(
        home.path(),
        &[
            "claude",
            path.to_str().unwrap(),
            "--before",
            &start.to_string(),
        ],
    );
    let again = g.next_of("hello");
    assert!(again["start"].as_u64().unwrap() < start);
    let more = keys(&g.next_of("items")["items"]);
    assert!(more.len() > first.len());
    // The same rows at the end, earlier ones in front.
    assert_eq!(more[more.len() - first.len()..], first[..]);
}

#[test]
fn a_file_cut_short_is_read_again() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    append(&path, &[user("u1", "one"), user("u2", "two")]);
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    f.next_of("items");
    fs::write(&path, format!("{}\n", user("u9", "rewritten"))).unwrap();
    f.next_of("hello");
    assert_eq!(keys(&f.next_of("items")["items"]), vec!["u9"]);
}

#[test]
fn the_status_line_snapshot_fills_in_what_the_transcript_lacks() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    append(&path, &[user("u1", "hi"), reply("a1", "ok")]);
    let f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    let plain = f.next_of("status");
    assert_eq!(plain["model"], "Opus 5.5");
    assert_eq!(plain["context_tokens"], 90_010);
    assert_eq!(plain["context_window"], Value::Null);
    // What `statusline` keeps for this session.
    let snap = home
        .path()
        .join(".local/state/attache/claude/s1/status.json");
    fs::create_dir_all(snap.parent().unwrap()).unwrap();
    fs::write(
        &snap,
        json!({ "session_id": "s1", "model": { "id": "claude-opus-5-5", "display_name": "Opus 5.5" },
                "context_window": { "context_window_size": 1_000_000 }, "cost": { "total_cost_usd": 1.25 },
                "prompt_cache": { "warm": true, "expires_at": 1_800_000_000u64 },
                "rate_limits": { "five_hour": { "used_percentage": 3.4, "resets_at": 1_800_001_000u64 } } })
        .to_string(),
    )
    .unwrap();
    let full = f.until(|e| e["t"] == "status" && e["context_window"] == 1_000_000);
    assert_eq!(full["context_percent"], 9);
    assert_eq!(full["cost_usd"], 1.25);
    assert_eq!(full["cache_expires_at"], 1_800_000_000u64);
    assert_eq!(
        full["limits"],
        json!([{ "label": "5-hour", "used_percent": 3, "resets_at": 1_800_001_000u64 }])
    );
}

#[test]
fn it_ends_when_whoever_started_it_goes() {
    let home = tempfile::tempdir().unwrap();
    let path = transcript(home.path(), "s1");
    append(&path, &[user("u1", "hi")]);
    let mut f = Follower::start(home.path(), &["claude", path.to_str().unwrap()]);
    f.next_of("items");
    drop(f.child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(2);
    while f.child.try_wait().unwrap().is_none() {
        assert!(
            Instant::now() < deadline,
            "still running after its stdin closed"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn agy_status_comes_from_its_settings_and_its_transcript() {
    let home = tempfile::tempdir().unwrap();
    let settings = home.path().join(".gemini/antigravity-cli/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, r#"{"model": "Gemini 4 Argon (Medium)"}"#).unwrap();
    let path = home
        .path()
        .join(".gemini/antigravity-cli/brain/x/.system_generated/logs/transcript_full.jsonl");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    append(
        &path,
        &[json!({ "step_index": 0, "type": "PLANNER_RESPONSE", "status": "DONE", "content": "好", "input_tokens": 100, "cache_read_tokens": 900 }).to_string()],
    );
    let f = Follower::start(home.path(), &["agy", path.to_str().unwrap()]);
    assert_eq!(f.next_of("items")["items"][0]["text"], "好");
    let s = f.next_of("status");
    assert_eq!(
        (
            s["model"].as_str(),
            s["effort"].as_str(),
            s["context_tokens"].as_u64()
        ),
        (Some("Gemini 4 Argon (Medium)"), Some("medium"), Some(1000))
    );
}

#[test]
fn only_a_transcript_is_followed() {
    let out = Command::new(env!("CARGO_BIN_EXE_attache-cli"))
        .args(["follow", "claude", "relative.jsonl"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    let out = Command::new(env!("CARGO_BIN_EXE_attache-cli"))
        .args(["follow", "codex", "/a.jsonl"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
}
