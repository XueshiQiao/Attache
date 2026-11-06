//! `agents` and `seen` against a real tmux server of their own (`-L`, on
//! every command), a real process in a real pane, and a Claude session file
//! made for it in a home folder of the test's own.

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

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
    socket_path: Option<String>,
}

impl Server {
    fn start(tmux: PathBuf) -> Server {
        let socket = format!("attache-cli-test-{}", std::process::id());
        let ok = Command::new(&tmux)
            .args([
                "-L",
                &socket,
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "probe",
                "sleep 300",
            ])
            .status()
            .unwrap();
        assert!(ok.success());
        let mut s = Server {
            tmux,
            socket,
            socket_path: None,
        };
        s.socket_path = Some(
            s.tmux(&["display-message", "-p", "-t", "probe", "#{socket_path}"])
                .trim()
                .to_owned(),
        );
        s
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = Command::new(&self.tmux)
            .arg("-L")
            .arg(&self.socket)
            .args(args)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux)
            .arg("-L")
            .arg(&self.socket)
            .arg("kill-server")
            .status();
        // tmux 3.6a leaves the socket file behind.
        if let Some(p) = self
            .socket_path
            .as_ref()
            .filter(|p| p.ends_with(&self.socket))
        {
            let _ = fs::remove_file(p);
        }
    }
}

fn run(home: &Path, server: &Server, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_attache-cli"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env(
            "PATH",
            format!(
                "{}:/usr/bin:/bin:/usr/sbin",
                server.tmux.parent().unwrap().display()
            ),
        )
        .env("ATTACHE_TMUX_SOCKET", &server.socket)
        .output()
        .unwrap()
}

fn agents(home: &Path, server: &Server) -> Vec<Value> {
    String::from_utf8_lossy(&run(home, server, &["agents"]).stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn a_real_pane_with_a_claude_session_file_reads_done_then_idle_once_seen() {
    let Some(tmux) = tmux_bin() else { return };
    let server = Server::start(tmux);
    let home = tempfile::tempdir().unwrap();
    let pane = server
        .tmux(&["display-message", "-p", "-t", "probe", "#{pane_id}"])
        .trim()
        .to_owned();
    let pid: u32 = server
        .tmux(&["display-message", "-p", "-t", "probe", "#{pane_pid}"])
        .trim()
        .parse()
        .unwrap();

    // Nothing in the pane looks like an agent yet.
    assert!(agents(home.path(), &server).is_empty());

    // The pane's process is now, as far as anything can tell, Claude.
    let sessions = home.path().join(".claude/sessions");
    fs::create_dir_all(&sessions).unwrap();
    let ended_ms = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        - 60)
        * 1000;
    fs::write(
        sessions.join(format!("{pid}.json")),
        json!({ "pid": pid, "sessionId": "s1", "cwd": "/w", "status": "idle", "statusUpdatedAt": ended_ms }).to_string(),
    )
    .unwrap();
    let transcript = home.path().join(".claude/projects/-w/s1.jsonl");
    fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    fs::write(&transcript, "{}\n").unwrap();

    let list = agents(home.path(), &server);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["pane"], pane.as_str());
    assert_eq!(list[0]["kind"], "claude");
    assert_eq!(list[0]["session"], "probe");
    assert_eq!(list[0]["conversation"], "s1");
    assert_eq!(list[0]["state"], "done");
    assert_eq!(list[0]["transcript"], transcript.to_string_lossy().as_ref());

    assert!(run(home.path(), &server, &["seen", "claude", "s1"])
        .status
        .success());
    assert_eq!(agents(home.path(), &server)[0]["state"], "idle");

    // One pane asked about by id.
    let one = run(home.path(), &server, &["agents", "--pane", &pane]);
    assert_eq!(String::from_utf8_lossy(&one.stdout).lines().count(), 1);
    let none = run(home.path(), &server, &["agents", "--pane", "%99999"]);
    assert!(none.stdout.is_empty());
}
