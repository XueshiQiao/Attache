//! `screen` and the checks `input` makes before it presses anything, against
//! a real tmux server of its own (`-L` on every command). The agent is a
//! copy of bash named `claude`, so the process table says Claude, drawing a
//! Claude screen from a file and writing down every key it receives: the
//! screen stays what the case set, and what arrived is read from the file.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

fn tmux_bin() -> Option<PathBuf> {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
}

const RULE: &str = "────────────────────────────────────────";

fn screens(dir: &Path) {
    let idle = format!("● Done.\n\n{RULE}\n❯ \n{RULE}\n  ? for shortcuts\n");
    let working = format!(
        "● Reading files\n\n✻ Jitterbugging… (13s · ↓ 649 tokens · esc to interrupt)\n  ⎿  Tip: Run Claude Code locally\n\n{RULE}\n❯ \n{RULE}\n  esc to interrupt\n"
    );
    let menu = format!("{RULE}\n Bash command\n\n   touch /tmp/x.txt\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and always allow access to /tmp from this project\n   3. No\n\n Esc to cancel · Tab to amend\n");
    let panel = "Settings  Status  Config  Usage\n\nCurrent session  3% used\n\nEsc to exit\n".to_owned();
    let menu2 = menu.replace("touch /tmp/x.txt", "rm -rf /tmp/*");
    let panel2 = panel.replace("3% used", "4% used");
    let agy_menu = "  Allow this command?\n  > Yes\n    No\n\n  ↑/↓ navigate · enter select · esc skip\n".to_owned();
    for (name, text) in [("idle", idle), ("working", working), ("menu", menu), ("menu2", menu2),
                         ("panel", panel), ("panel2", panel2), ("blank", String::new()), ("agy_menu", agy_menu)] {
        fs::write(dir.join(format!("{name}.txt")), text).unwrap();
    }
    // A question Claude asked: `@k` is where the cursor mark goes.
    fs::write(
        dir.join("ask.txt"),
        format!("{RULE}\n ☐ Hook\n\n│ The commit hook failed. What should I do?\n\n@1 1. Skip the hook (Recommended)\n     Commit with --no-verify.\n@2 2. Allow esbuild\n     Write pnpm-workspace.yaml.\n@3 3. Do not commit\n@4 4. Type something.\n{RULE}\n@5 5. Chat about this\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"),
    )
    .unwrap();
    // The same question on an agent that ignores arrows: drawn once, cursor
    // on the first answer for good.
    let stuck = fs::read_to_string(dir.join("ask.txt")).unwrap().replacen("@1 ", "❯ ", 1);
    fs::write(dir.join("askstuck.txt"), stuck.replace("@2 ", "  ").replace("@3 ", "  ").replace("@4 ", "  ").replace("@5 ", "  ")).unwrap();
    // An agent whose cursor moves on the arrows, as Claude's does, and
    // which writes down the answer an Enter picked.
    fs::write(
        dir.join("ask.sh"),
        r#"D=$(dirname "$0")
: > "$D/keys"; : > "$D/got"
stty -echo
c=1
draw() { printf '\033[H\033[2J'; sed -e "s/^@$c /❯ /" -e 's/^@[0-9] /  /' "$D/ask.txt"; }
draw
buf=
while IFS= read -rsn1 k; do
  if [ -z "$k" ]; then printf 'chose %s\n' "$c" >> "$D/got"; buf=
  else buf="$buf$k"; printf '%s' "$k" >> "$D/keys"
    case "$buf" in *'[B') c=$((c+1)); buf=; draw ;; *'[A') c=$((c-1)); buf=; draw ;; esac
  fi
done
"#,
    )
    .unwrap();
    fs::write(
        dir.join("fake.sh"),
        r#"D=$(dirname "$0")
: > "$D/keys"; : > "$D/got"
stty -echo
printf '\033[H\033[2J'; cat "$D/$1.txt"
buf=
while IFS= read -rsn1 k; do
  if [ -z "$k" ]; then printf '%s\n' "$buf" >> "$D/got"; buf=
  else buf="$buf$k"; printf '%s' "$k" >> "$D/keys"
    # A menu that comes up while a message is being typed.
    case "$buf" in *SWITCH) printf '\033[H\033[2J'; cat "$D/menu.txt" ;; esac
  fi
done
"#,
    )
    .unwrap();
}

struct Server {
    tmux: PathBuf,
    socket: String,
    home: tempfile::TempDir,
}

impl Server {
    fn start(tmux: PathBuf, name: &str) -> Server {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        for name in ["claude", "agy"] {
            fs::copy("/bin/bash", bin.join(name)).unwrap();
            // macOS kills a copied system binary on launch (exit 137) until
            // it carries a signature of its own.
            if cfg!(target_os = "macos") {
                // One at a time: `codesign` run by several tests at once
                // fails some of them, with nothing wrong with the file.
                static SIGNING: std::sync::Mutex<()> = std::sync::Mutex::new(());
                let _one = SIGNING.lock().unwrap_or_else(|e| e.into_inner());
                let out = Command::new("codesign").args(["-s", "-", "-f"]).arg(bin.join(name)).output().unwrap();
                assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
            }
        }
        screens(home.path());
        let socket = format!("attache-cli-screen-{name}-{}", std::process::id());
        let s = Server { tmux, socket, home };
        assert!(Command::new(&s.tmux)
            .args(["-L", &s.socket, "-f", "/dev/null", "new-session", "-d", "-s", "probe", "-x", "200", "-y", "40", "cat"])
            .status()
            .unwrap()
            .success());
        s
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = Command::new(&self.tmux)
            .arg("-u")
            .arg("-L")
            .arg(&self.socket)
            .args(args)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn pane(&self) -> String {
        self.tmux(&["display-message", "-p", "-t", "probe", "#{pane_id}"]).trim().to_owned()
    }

    /// Restarts the pane as `claude` showing `screen`, and waits for it.
    fn show(&self, screen: &str) {
        self.show_as("claude", screen)
    }

    fn show_as(&self, agent: &str, screen: &str) {
        let dir = self.home.path();
        let script = if screen == "ask" { "ask.sh" } else { "fake.sh" };
        let cmd = format!("'{}' '{}' {screen}", dir.join("bin").join(agent).display(), dir.join(script).display());
        self.tmux(&["respawn-pane", "-k", "-t", "probe", &cmd]);
        self.tmux(&["clear-history", "-t", "probe"]);
        let want = fs::read_to_string(dir.join(format!("{screen}.txt"))).unwrap().replace("@1 ", "❯ ");
        let deadline = Instant::now() + Duration::from_secs(3);
        if let Some(first) = want.lines().find(|l| !l.trim().is_empty()).map(|l| l.trim().to_owned()) {
            while !self.tmux(&["capture-pane", "-p", "-t", "probe"]).contains(&first) {
                assert!(Instant::now() < deadline, "{screen} never drawn");
                std::thread::sleep(Duration::from_millis(30));
            }
        } else {
            std::thread::sleep(Duration::from_millis(300));
        }
        // The key log is truncated by the script once it starts.
        std::thread::sleep(Duration::from_millis(100));
    }

    fn cli(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_attache-cli"))
            .args(args)
            .env_clear()
            .env("HOME", self.home.path())
            .env("PATH", format!("{}:/usr/bin:/bin:/usr/sbin", self.tmux.parent().unwrap().display()))
            .env("ATTACHE_TMUX_SOCKET", &self.socket)
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let o = self.cli(args);
        serde_json::from_slice(&o.stdout).unwrap_or_else(|_| panic!("{args:?}: {}", String::from_utf8_lossy(&o.stdout)))
    }

    /// What reached the agent, once nothing more is arriving.
    fn keys(&self) -> String {
        std::thread::sleep(Duration::from_millis(300));
        fs::read_to_string(self.home.path().join("keys")).unwrap_or_default()
    }

    /// Writes the Claude session file that says what the agent in the pane
    /// is doing, the way Claude Code writes its own.
    fn session(&self, status: &str) {
        let pid = self.tmux(&["display-message", "-p", "-t", "probe", "#{pane_pid}"]).trim().to_owned();
        let dir = self.home.path().join(".claude/sessions");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(format!("{pid}.json")),
            format!(r#"{{"pid":{pid},"sessionId":"s1","cwd":"/tmp","status":"{status}","statusUpdatedAt":1}}"#),
        )
        .unwrap();
    }

    fn got(&self) -> String {
        std::thread::sleep(Duration::from_millis(300));
        fs::read_to_string(self.home.path().join("got")).unwrap_or_default()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux).args(["-L", &self.socket, "kill-server"]).status();
    }
}

fn refused(v: &Value, why: &str) {
    assert_eq!(v["sent"], false, "{v}");
    assert_eq!(v["why"], why, "{v}");
}

fn b64(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in s.as_bytes().chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |acc, (i, x)| acc | (*x as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() { T[(n >> (18 - 6 * i) & 63) as usize] as char } else { '=' });
        }
    }
    out
}

#[test]
fn the_idle_prompt_takes_a_message_and_no_key() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "idle");
    let pane = s.pane();
    s.show("idle");
    let v = s.json(&["screen", &pane]);
    assert_eq!(v["kind"], "claude", "{v}");
    assert_eq!(v["prompt"], true, "{v}");
    assert!(v["approval"].is_null() && v["panel"].is_null() && v["activity"].is_null(), "{v}");
    // An Esc here is half of the two that open the rewind menu, a Tab turns
    // thinking on or off: neither may arrive.
    refused(&s.json(&["input", &pane, "--key", "Escape", "--if", "working"]), "not_working");
    refused(&s.json(&["input", &pane, "--key", "Tab", "--if", "panel"]), "panel_closed");
    refused(&s.json(&["input", &pane, "--key", "1", "--if", "approval:0123456789abcdef"]), "question_gone");
    assert_eq!(s.keys(), "");
    assert_eq!(s.json(&["input", &pane, "--text", &b64("hello there"), "--enter"])["sent"], true);
    assert_eq!(s.got(), "hello there\n");
}

#[test]
fn a_running_turn_takes_esc_and_only_esc() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "working");
    let pane = s.pane();
    s.show("working");
    let v = s.json(&["screen", &pane]);
    assert_eq!(v["activity"]["verb"], "Jitterbugging…", "{v}");
    assert_eq!(s.cli(&["input", &pane, "--key", "Tab", "--if", "working"]).status.code(), Some(2));
    // The line alone is drawn text; Claude's own file has to say busy too.
    refused(&s.json(&["input", &pane, "--key", "Escape", "--if", "working"]), "not_working");
    s.session("idle");
    refused(&s.json(&["input", &pane, "--key", "Escape", "--if", "working"]), "not_working");
    assert_eq!(s.keys(), "");
    s.session("busy");
    assert_eq!(s.json(&["input", &pane, "--key", "Escape", "--if", "working"])["sent"], true);
    assert_eq!(s.keys(), "\x1b");
}

#[test]
fn an_approval_takes_its_own_digit_on_its_own_menu() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "menu");
    let pane = s.pane();
    s.show("menu");
    let v = s.json(&["screen", &pane]);
    let fp = v["approval"]["fingerprint"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned();
    assert_eq!(v["approval"]["options"].as_array().unwrap().len(), 3);
    assert_eq!(v["prompt"], false);
    let cond = format!("approval:{fp}");
    refused(&s.json(&["input", &pane, "--key", "2", "--if", "approval:0123456789abcdef"]), "question_changed");
    refused(&s.json(&["input", &pane, "--key", "4", "--if", &cond]), "no_such_option");
    // Letters here are answers to a question nobody read.
    refused(&s.json(&["input", &pane, "--text", &b64("yes do it"), "--enter"]), "question");
    refused(&s.json(&["input", &pane, "--key", "Escape", "--if", "working"]), "not_working");
    assert_eq!(s.keys(), "");
    // The same question and answers about another command is another menu.
    s.show("menu2");
    refused(&s.json(&["input", &pane, "--key", "1", "--if", &cond]), "question_changed");
    assert_eq!(s.keys(), "");
    s.show("menu");
    assert_eq!(s.json(&["input", &pane, "--key", "2", "--if", &cond])["sent"], true);
    assert_eq!(s.keys(), "2");
}

#[test]
fn a_panel_takes_its_keys_and_no_message() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "panel");
    let pane = s.pane();
    s.show("panel");
    let v = s.json(&["screen", &pane]);
    assert!(v["panel"].is_array(), "{v}");
    // Its Enter would choose whatever the panel has selected.
    refused(&s.json(&["input", &pane, "--text", &b64("/model"), "--enter"]), "panel");
    assert_eq!(s.keys(), "");
    assert_eq!(s.json(&["input", &pane, "--key", "Down", "--if", "panel"])["sent"], true);
    assert_eq!(s.keys(), "\x1b[B");
    // Enter chooses: only on the very panel it was meant for.
    let fp = v["panel_fingerprint"].as_str().unwrap().to_owned();
    s.show("panel2");
    refused(&s.json(&["input", &pane, "--key", "Enter", "--if", &format!("panel:{fp}")]), "panel_changed");
    assert_eq!(s.keys(), "");
    s.show("panel");
    assert_eq!(s.json(&["input", &pane, "--key", "Enter", "--if", &format!("panel:{fp}")])["sent"], true);
    // The agent reads an Enter as the end of a line.
    assert_eq!(s.got(), "\n");
}

#[test]
fn a_key_reaches_the_agent_through_copy_mode() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "copymode");
    let pane = s.pane();
    s.show("panel");
    s.tmux(&["copy-mode", "-t", &pane]);
    assert_eq!(s.tmux(&["display-message", "-p", "-t", &pane, "#{pane_in_mode}"]).trim(), "1");
    assert_eq!(s.json(&["input", &pane, "--key", "Down", "--if", "panel"])["sent"], true);
    // Arrived as the agent's key, not eaten by copy mode.
    assert_eq!(s.keys(), "\x1b[B");
}

#[test]
fn a_message_needs_the_box_and_its_enter_waits_for_a_second_look() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "text");
    let pane = s.pane();
    s.show("blank");
    refused(&s.json(&["input", &pane, "--text", &b64("hello"), "--enter"]), "no_prompt");
    assert_eq!(s.keys(), "");
    // A menu that comes up while the message goes in keeps its Enter.
    s.show("idle");
    refused(&s.json(&["input", &pane, "--text", &b64("now SWITCH"), "--enter"]), "enter_withheld");
    assert_eq!(s.got(), "", "no Enter reached the menu");
    // agy waiting on its own menu takes no message either.
    s.show_as("agy", "agy_menu");
    refused(&s.json(&["input", &pane, "--text", &b64("hi"), "--enter"]), "question");
    assert_eq!(s.keys(), "");
}

#[test]
fn a_pane_someone_else_is_typing_into_is_busy() {
    use std::os::unix::io::AsRawFd;
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "busy");
    let pane = s.pane();
    s.show("idle");
    let dir = s.home.path().join(".local/state/attache/input");
    fs::create_dir_all(&dir).unwrap();
    let held = fs::File::create(dir.join(format!("{}.lock", &pane[1..]))).unwrap();
    assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX) }, 0);
    let started = Instant::now();
    refused(&s.json(&["input", &pane, "--text", &b64("hello"), "--enter"]), "busy");
    assert!(started.elapsed() >= Duration::from_secs(9), "waited for the lock first");
    assert_eq!(s.keys(), "");
}

#[test]
fn watch_pushes_the_pane_when_its_screen_changes_and_ends_with_stdin() {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    use std::sync::mpsc;
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "watch");
    let pane = s.pane();
    s.show("idle");
    let mut child = Command::new(env!("CARGO_BIN_EXE_attache-cli"))
        .args(["agents", "--watch", "--pane", &pane])
        .env_clear()
        .env("HOME", s.home.path())
        .env("PATH", format!("{}:/usr/bin:/bin:/usr/sbin", s.tmux.parent().unwrap().display()))
        .env("ATTACHE_TMUX_SOCKET", &s.socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let (tx, rx) = mpsc::channel::<Value>();
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(serde_json::from_str(&line).unwrap()).is_err() {
                return;
            }
        }
    });
    let next = |t: &str| loop {
        let v = rx.recv_timeout(Duration::from_secs(5)).unwrap_or_else(|_| panic!("no {t}"));
        if v["t"] == t {
            return v;
        }
    };
    let agents = next("agents");
    assert_eq!(agents["agents"][0]["kind"], "claude", "{agents}");
    assert_eq!(next("screen")["prompt"], true);
    s.show("menu");
    let v = next("screen");
    assert!(v["approval"]["fingerprint"].is_string(), "{v}");
    // Nothing more while nothing changes.
    assert!(rx.recv_timeout(Duration::from_millis(1500)).is_err());
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "still running after stdin ended");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_question_is_answered_by_moving_to_the_answer_and_looking_again() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "ask");
    let pane = s.pane();
    s.show("ask");
    let v = s.json(&["screen", &pane]);
    let q = &v["question"];
    assert_eq!(q["cursor"], 1, "{v}");
    assert_eq!(q["options"].as_array().unwrap().len(), 5);
    let cond = format!("question:{}", q["fingerprint"].as_str().unwrap());
    // Answers that need typing are the terminal's.
    refused(&s.json(&["input", &pane, "--choose", "4", "--if", &cond]), "typed_answer");
    refused(&s.json(&["input", &pane, "--choose", "2", "--if", "question:0123456789abcdef"]), "question_changed");
    refused(&s.json(&["input", &pane, "--choose", "9", "--if", &cond]), "no_such_option");
    assert_eq!(s.keys(), "");
    assert_eq!(s.json(&["input", &pane, "--choose", "3", "--if", &cond])["sent"], true);
    assert_eq!(s.got(), "chose 3\n");
    // Two Downs, then the Enter.
    assert_eq!(s.keys(), "\x1b[B\x1b[B");
}

#[test]
fn a_question_whose_cursor_did_not_arrive_gets_no_enter() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "askstuck");
    let pane = s.pane();
    s.show("askstuck");
    let fp = s.json(&["screen", &pane])["question"]["fingerprint"].as_str().unwrap().to_owned();
    let cond = format!("question:{fp}");
    // The arrows go; the cursor stays; the second look sees it and the
    // Enter is held back.
    refused(&s.json(&["input", &pane, "--choose", "3", "--if", &cond]), "question_changed");
    assert_eq!(s.keys(), "\x1b[B\x1b[B");
    assert_eq!(s.got(), "");
    // And a question gone by the time the answer arrives gets no key at all.
    s.show("menu");
    refused(&s.json(&["input", &pane, "--choose", "2", "--if", &cond]), "question_gone");
    assert_eq!(s.keys(), "");
}
