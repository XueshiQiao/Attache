//! `input` against a real tmux server of its own (`-L` on every command),
//! with `cat` in the pane standing in for an agent: what arrives is echoed,
//! and the screen shows whether each message arrived whole.

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{Duration, Instant};

fn tmux_bin() -> Option<PathBuf> {
    [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    .iter()
    .map(PathBuf::from)
    .find(|p| p.exists())
}

struct Server {
    tmux: PathBuf,
    socket: String,
    socket_path: String,
    home: tempfile::TempDir,
}

impl Server {
    fn start(tmux: PathBuf, name: &str) -> Server {
        // `cat` stands in for an agent, named `codex` so attache-cli knows it
        // as one (by name only, with no screen reader): a pane with no agent
        // in it takes no message at all.
        let home = tempfile::tempdir().unwrap();
        let agent = home.path().join("codex");
        fs::copy("/bin/cat", &agent).unwrap();
        // macOS kills a copied system binary on launch until it carries a
        // signature of its own.
        if cfg!(target_os = "macos") {
            assert!(Command::new("codesign").args(["-s", "-", "-f"]).arg(&agent)
                .output().unwrap().status.success());
        }
        let socket = format!("attache-cli-input-{name}-{}", std::process::id());
        assert!(Command::new(&tmux)
            .args([
                "-L",
                &socket,
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "probe",
                "-x",
                "300",
                "-y",
                "60",
                agent.to_str().unwrap()
            ])
            .status()
            .unwrap()
            .success());
        let mut s = Server {
            tmux,
            socket,
            socket_path: String::new(),
            home,
        };
        s.socket_path = s
            .tmux(&["display-message", "-p", "-t", "probe", "#{socket_path}"])
            .trim()
            .to_owned();
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
        self.tmux(&["display-message", "-p", "-t", "probe", "#{pane_id}"])
            .trim()
            .to_owned()
    }

    fn input(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_attache-cli"))
            .arg("input")
            .args(args)
            .env_clear()
            .env("HOME", self.home.path())
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.tmux.parent().unwrap().display()),
            )
            .env("ATTACHE_TMUX_SOCKET", &self.socket)
            .output()
            .unwrap()
    }

    /// The screen once it shows `want`, within 3 s.
    fn screen_with(&self, want: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let screen = self.tmux(&["capture-pane", "-p", "-J", "-t", "probe"]);
            if screen.contains(want) || Instant::now() > deadline {
                return screen;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux)
            .arg("-L")
            .arg(&self.socket)
            .arg("kill-server")
            .status();
        if self.socket_path.ends_with(&self.socket) {
            let _ = fs::remove_file(&self.socket_path);
        }
    }
}

fn b64(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = s.as_bytes();
    let mut out = String::new();
    for chunk in b.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, x)| acc | (*x as u32) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[test]
fn a_message_is_pasted_and_sent_and_a_command_is_typed() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "basic");
    let pane = s.pane();
    assert!(s
        .input(&[&pane, "--text", &b64("你好 world"), "--enter"])
        .status
        .success());
    // cat echoes the line as typed, then prints it back.
    let screen = s.screen_with("你好 world\n你好 world");
    assert!(screen.contains("你好 world\n你好 world"), "{screen}");
    assert!(s
        .input(&[&pane, "--text", &b64("/clear"), "--enter"])
        .status
        .success());
    assert!(s.screen_with("/clear\n/clear").contains("/clear\n/clear"));
}

#[test]
fn a_pane_in_copy_mode_still_gets_the_message() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "copy");
    let pane = s.pane();
    s.tmux(&["copy-mode", "-t", &pane]);
    assert_eq!(
        s.tmux(&["display-message", "-p", "-t", &pane, "#{pane_in_mode}"])
            .trim(),
        "1"
    );
    assert!(s
        .input(&[&pane, "--text", &b64("after scrolling"), "--enter"])
        .status
        .success());
    assert!(s
        .screen_with("after scrolling\nafter scrolling")
        .contains("after scrolling\nafter scrolling"));
}

#[test]
fn messages_sent_at_once_arrive_whole() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "race");
    let pane = s.pane();
    let texts: Vec<String> = (0..6)
        .map(|i| format!("message-{i}-{}", "x".repeat(120)))
        .collect();
    std::thread::scope(|scope| {
        for t in &texts {
            let (s, pane) = (&s, &pane);
            scope.spawn(move || {
                assert!(s
                    .input(&[pane, "--text", &b64(t), "--enter"])
                    .status
                    .success())
            });
        }
    });
    let screen = s.screen_with(&texts[5]);
    for t in &texts {
        // Echoed and printed back, each on a line of its own.
        assert_eq!(
            screen.lines().filter(|l| l == t).count(),
            2,
            "{t} not whole in:\n{screen}"
        );
    }
}

#[test]
fn only_known_keys_are_pressed() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "keys");
    let pane = s.pane();
    // A key names the screen it is for, or it is not a request at all.
    assert_eq!(s.input(&[&pane, "--key", "Enter"]).status.code(), Some(2));
    assert_eq!(s.input(&[&pane, "--key", "C-c", "--if", "panel"]).status.code(), Some(2));
    assert_eq!(s.input(&["probe", "--key", "Enter", "--if", "panel"]).status.code(), Some(2));
    assert_eq!(
        s.input(&[&pane, "--text", "not base64!"]).status.code(),
        Some(2)
    );
    // `codex` is no Claude: there is no screen to check a key against.
    // Enter chooses, so it names the very panel it is for.
    assert_eq!(s.input(&[&pane, "--key", "Enter", "--if", "panel"]).status.code(), Some(2));
    let o = s.input(&[&pane, "--key", "Down", "--if", "panel"]);
    assert_eq!(o.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&o.stdout).contains("not_claude"));
}
