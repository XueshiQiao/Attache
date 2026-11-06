//! The binary itself, run as its callers run it, against a home folder of
//! its own. tmux is a recorder (`ATTACHE_TMUX`): a real `tmux` would find
//! the owner's server by user id whatever `HOME` says.

use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

struct Host {
    home: tempfile::TempDir,
}

impl Host {
    fn new() -> Host {
        let host = Host {
            home: tempfile::tempdir().unwrap(),
        };
        let fake = host.path("bin/tmux");
        fs::create_dir_all(fake.parent().unwrap()).unwrap();
        fs::write(
            &fake,
            format!(
                "#!/bin/sh\n[ \"$1\" = -u ] && shift\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1\" in\n  list-sessions) printf '$1\\n$2\\n' ;;\n  display-message) printf 'win\\n' ;;\nesac\n",
                host.path("tmux.log").display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        host
    }

    fn path(&self, rel: &str) -> PathBuf {
        self.home.path().join(rel)
    }

    fn command(&self, bin: &Path) -> Command {
        let mut c = Command::new(bin);
        c.env_clear()
            .env("HOME", self.home.path())
            .env("PATH", "/usr/bin:/bin")
            .env("ATTACHE_TMUX", self.path("bin/tmux"));
        c
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(Path::new(env!("CARGO_BIN_EXE_attache-cli")))
            .args(args)
            .output()
            .unwrap()
    }

    fn run_with_input(&self, args: &[&str], input: &str) -> Output {
        let mut child = self
            .command(Path::new(env!("CARGO_BIN_EXE_attache-cli")))
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    }

    fn tmux_log(&self) -> String {
        fs::read_to_string(self.path("tmux.log")).unwrap_or_default()
    }

    fn settings(&self) -> Value {
        serde_json::from_slice(&fs::read(self.path(".claude/settings.json")).unwrap()).unwrap()
    }

    fn write_settings(&self, v: &Value) {
        fs::create_dir_all(self.path(".claude")).unwrap();
        fs::write(
            self.path(".claude/settings.json"),
            serde_json::to_string_pretty(v).unwrap(),
        )
        .unwrap();
    }
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

fn json_line(o: &Output) -> Value {
    serde_json::from_str(stdout(o).trim()).unwrap()
}

fn ours() -> String {
    format!("'{}' statusline claude", env!("CARGO_BIN_EXE_attache-cli"))
}

#[test]
fn version_names_the_protocol() {
    let v = json_line(&Host::new().run(&["version"]));
    assert_eq!(v["protocol"], 1);
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
}

#[test]
fn send_queues_the_file_and_rings_the_phone_as_attache_send_did() {
    let host = Host::new();
    let file = host.path("report.txt");
    fs::write(&file, "x").unwrap();
    let out = host.run(&["send", file.to_str().unwrap()]);
    assert!(out.status.success());
    let abs = file.canonicalize().unwrap();
    assert_eq!(
        fs::read_to_string(host.path(".local/share/attache/outbox.queue")).unwrap(),
        format!("{}\n", abs.display())
    );
    let log = host.tmux_log();
    let push = log
        .lines()
        .find(|l| l.starts_with("set -g @attache_push "))
        .unwrap();
    assert!(push.ends_with(&format!(":{}", abs.display())));
    // Every session's window renamed to its own name, which wakes the phone.
    assert!(log.contains("rename-window -t $1 win"));
    assert!(log.contains("rename-window -t $2 win"));
}

#[test]
fn send_refuses_a_missing_file_and_queues_nothing() {
    let host = Host::new();
    let out = host.run(&["send", host.path("nope").to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(1));
    assert!(!host.path(".local/share/attache/outbox.queue").exists());
    assert!(host.tmux_log().is_empty());
}

#[test]
fn called_attache_send_it_sends() {
    let host = Host::new();
    let link = host.path("bin/attache-send");
    std::os::unix::fs::symlink(env!("CARGO_BIN_EXE_attache-cli"), &link).unwrap();
    let file = host.path("a.png");
    fs::write(&file, "x").unwrap();
    assert!(host
        .command(&link)
        .arg(&file)
        .output()
        .unwrap()
        .status
        .success());
    assert!(
        fs::read_to_string(host.path(".local/share/attache/outbox.queue"))
            .unwrap()
            .ends_with("a.png\n")
    );
}

fn snapshot(session: &str, duration: u64) -> String {
    json!({ "session_id": session, "model": { "display_name": "Opus" }, "cost": { "total_duration_ms": duration },
            "rate_limits": { "seven_day": { "used_percentage": 9 } } })
    .to_string()
}

fn stored(host: &Host, session: &str) -> Value {
    serde_json::from_slice(
        &fs::read(host.path(&format!(
            ".local/state/attache/claude/{session}/status.json"
        )))
        .unwrap(),
    )
    .unwrap()
}

#[test]
fn the_status_line_is_kept_per_session_and_an_older_one_is_dropped() {
    let host = Host::new();
    host.run_with_input(&["statusline", "claude"], &snapshot("s1", 500));
    host.run_with_input(&["statusline", "claude"], &snapshot("s2", 10));
    // A refresh that finished late, carrying an older snapshot.
    host.run_with_input(&["statusline", "claude"], &snapshot("s1", 400));
    assert_eq!(stored(&host, "s1")["cost"]["total_duration_ms"], 500);
    assert_eq!(stored(&host, "s2")["cost"]["total_duration_ms"], 10);
    host.run_with_input(&["statusline", "claude"], &snapshot("s1", 900));
    assert_eq!(stored(&host, "s1")["cost"]["total_duration_ms"], 900);
}

#[test]
fn a_session_id_cannot_write_outside_the_state_folder() {
    let host = Host::new();
    host.run_with_input(&["statusline", "claude"], &snapshot("../../evil", 1));
    assert!(!host.path(".local/state/evil").exists());
    assert!(!host.path(".local/state/attache/claude").exists());
}

#[test]
fn many_refreshes_at_once_leave_the_newest() {
    let host = Host::new();
    let children: Vec<_> = (1..=24u64)
        .map(|i| {
            let mut c = host
                .command(Path::new(env!("CARGO_BIN_EXE_attache-cli")))
                .args(["statusline", "claude"])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            c.stdin
                .take()
                .unwrap()
                .write_all(snapshot("s", (i * 7919) % 97).as_bytes())
                .unwrap();
            c
        })
        .collect();
    for mut c in children {
        c.wait().unwrap();
    }
    let max = (1..=24u64).map(|i| (i * 7919) % 97).max().unwrap();
    assert_eq!(stored(&host, "s")["cost"]["total_duration_ms"], max);
}

#[test]
fn the_line_drawn_is_the_one_configured_before() {
    let host = Host::new();
    host.write_settings(
        &json!({ "statusLine": { "type": "command", "command": "cat >/dev/null; echo before" } }),
    );
    assert_eq!(
        json_line(&host.run(&["setup"]))["claude_statusline"],
        "installed"
    );
    let out = host.run_with_input(&["statusline", "claude"], &snapshot("s", 1));
    assert_eq!(stdout(&out), "before\n");
}

#[test]
fn a_chain_back_to_itself_ends() {
    let host = Host::new();
    // A wrapped command that is, through some other wrapper, this program.
    host.write_settings(
        &json!({ "statusLine": { "type": "command", "command": "echo placeholder" } }),
    );
    host.run(&["setup"]);
    let record = host.path(".local/state/attache/claude/statusline.json");
    fs::write(
        &record,
        json!({ "original": { "type": "command", "command": format!("{} | cat", ours()) } })
            .to_string(),
    )
    .unwrap();
    // The record names this program, so it is not run at all.
    let out = host.run_with_input(&["statusline", "claude"], &snapshot("s", 1));
    assert_eq!(stdout(&out), "Opus\n");
    // And a call made from inside the chain stops at once.
    let guarded = host
        .command(Path::new(env!("CARGO_BIN_EXE_attache-cli")))
        .args(["statusline", "claude"])
        .env("ATTACHE_CLI_STATUSLINE", "1")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(guarded.stdout.is_empty());
}

#[test]
fn setup_on_a_fresh_home_installs_and_uninstall_leaves_nothing() {
    let host = Host::new();
    assert_eq!(
        json_line(&host.run(&["setup"]))["claude_statusline"],
        "installed"
    );
    assert_eq!(
        host.settings()["statusLine"],
        json!({ "type": "command", "command": ours() })
    );
    assert_eq!(
        json_line(&host.run(&["setup"]))["claude_statusline"],
        "already"
    );
    assert_eq!(
        json_line(&host.run(&["uninstall"]))["claude_statusline"],
        "removed"
    );
    assert_eq!(host.settings(), json!({}));
    assert_eq!(
        json_line(&host.run(&["uninstall"]))["claude_statusline"],
        "not-installed"
    );
}

#[test]
fn setup_keeps_everything_else_and_uninstall_puts_the_original_back() {
    let host = Host::new();
    let original = json!({
        "model": "opus",
        "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh", "padding": 0 },
        "hooks": { "Stop": [] }
    });
    host.write_settings(&original);
    host.run(&["setup"]);
    let installed = host.settings();
    assert_eq!(
        installed["statusLine"],
        json!({ "type": "command", "command": ours(), "padding": 0 })
    );
    // Same keys, same order.
    assert_eq!(
        installed.as_object().unwrap().keys().collect::<Vec<_>>(),
        vec!["model", "statusLine", "hooks"]
    );
    let backups = fs::read_dir(host.path(".claude")).unwrap().filter(|e| {
        e.as_ref()
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("settings.json.attache-backup-")
    });
    assert_eq!(backups.count(), 1);
    host.run(&["uninstall"]);
    assert_eq!(host.settings(), original);
}

#[test]
fn inside_the_desktop_wrapper_it_does_not_wrap_again() {
    let host = Host::new();
    let hooks = host.path(".claude/hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join("tmuxgui-statusline.conf"),
        format!("TMUXGUI_WRAPPED=command\nINNER={}\n", ours()),
    )
    .unwrap();
    let settings = json!({ "statusLine": { "type": "command", "command": "sh ~/.claude/hooks/tmuxgui-statusline.sh" } });
    host.write_settings(&settings);
    assert_eq!(
        json_line(&host.run(&["setup"]))["claude_statusline"],
        "inside-desktop-wrapper"
    );
    assert_eq!(host.settings(), settings);
}

#[test]
fn the_desktop_wrapper_wrapping_something_else_is_itself_wrapped() {
    let host = Host::new();
    let hooks = host.path(".claude/hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join("tmuxgui-statusline.conf"),
        "INNER=bash ~/.claude/statusline-command.sh\n",
    )
    .unwrap();
    host.write_settings(&json!({ "statusLine": { "type": "command", "command": "sh ~/.claude/hooks/tmuxgui-statusline.sh" } }));
    assert_eq!(
        json_line(&host.run(&["setup"]))["claude_statusline"],
        "installed"
    );
}

#[test]
fn a_settings_file_that_is_not_json_is_left_alone() {
    let host = Host::new();
    fs::create_dir_all(host.path(".claude")).unwrap();
    fs::write(host.path(".claude/settings.json"), "{ not json").unwrap();
    let out = host.run(&["setup"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(json_line(&out)["claude_statusline"], "failed");
    assert_eq!(
        fs::read_to_string(host.path(".claude/settings.json")).unwrap(),
        "{ not json"
    );
}
