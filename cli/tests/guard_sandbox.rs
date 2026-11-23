//! The privacy guard inside an agent's sandbox: agy's `--sandbox` denies
//! reads under `~/.config`, where the rules live, while its hooks run
//! outside it. So the hook leaves a copy of the rules beside the vault and
//! the command it wraps names that copy. This runs the real binary through
//! both halves: the hook with the rules readable, then the wrapped command
//! with them not — under a `sandbox-exec` profile that denies `~/.config`
//! on macOS, as agy's does, and with the file's read bits removed elsewhere.

use serde_json::Value;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};

const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

fn cli(home: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_attache-cli"));
    c.env("HOME", home).env_remove("XDG_STATE_HOME").env("SHELL", "/bin/sh");
    c
}

fn hook(home: &Path, command: &str) -> Value {
    let event = serde_json::json!({"toolCall": {"name": "run_command", "args": {"CommandLine": command}}});
    let mut child = cli(home).args(["guard", "hook", "agy-pre"]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(event.to_string().as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    serde_json::from_slice(&out.stdout).unwrap_or_else(|_| panic!("hook said {}", String::from_utf8_lossy(&out.stdout)))
}

/// Runs `command` the way agy would after the hook, with `~/.config` closed.
fn in_sandbox(home: &Path, command: &str) -> Option<Output> {
    let config = home.join(".config");
    let mut c = if Path::new(SANDBOX_EXEC).exists() {
        let profile = format!(
            "(version 1)(allow default)(deny file-read* (subpath {:?}))",
            fs::canonicalize(&config).unwrap().to_string_lossy()
        );
        let mut c = Command::new(SANDBOX_EXEC);
        c.args(["-p", &profile, "/bin/sh", "-c", command]);
        c
    } else {
        // Without the read bits root still reads the file: nothing to test.
        if unsafe { libc::geteuid() } == 0 {
            return None;
        }
        fs::set_permissions(config.join("attache-guard.toml"), fs::Permissions::from_mode(0o000)).unwrap();
        let mut c = Command::new("/bin/sh");
        c.args(["-c", command]);
        c
    };
    c.env("HOME", home).env_remove("XDG_STATE_HOME").env("SHELL", "/bin/sh");
    Some(c.output().unwrap())
}

#[test]
fn a_wrapped_command_runs_and_is_masked_where_the_rules_file_cannot_be_read() {
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    fs::create_dir_all(home.join(".config")).unwrap();
    fs::write(home.join(".config/attache-guard.toml"), "[[word]]\ntext = \"studio-mac\"\n").unwrap();

    let out = hook(home, "echo host studio-mac");
    assert_eq!(out["decision"], "allow", "{out}");
    let wrapped = out.pointer("/overwrite/CommandLine").and_then(Value::as_str).unwrap().to_owned();
    assert!(wrapped.contains("--rules-snapshot "), "{wrapped}");
    assert!(!wrapped.contains("studio-mac\"") && !wrapped.contains("[[word]]"), "no rule text in the command: {wrapped}");

    // The case that failed: the same command without a copy is refused.
    let bare = format!("{:?} guard run --agent agy --sh 'echo hi'", env!("CARGO_BIN_EXE_attache-cli"));
    let Some(refused) = in_sandbox(home, &bare) else { return };
    assert_eq!(refused.status.code(), Some(125), "{}", String::from_utf8_lossy(&refused.stderr));
    assert!(refused.stdout.is_empty());

    let ran = in_sandbox(home, &wrapped).unwrap();
    let stdout = String::from_utf8_lossy(&ran.stdout);
    assert_eq!(ran.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&ran.stderr));
    assert!(stdout.starts_with("host ⟦word:"), "{stdout}");
    assert!(!stdout.contains("studio-mac"), "{stdout}");

    fs::set_permissions(home.join(".config/attache-guard.toml"), fs::Permissions::from_mode(0o644)).unwrap();
}

fn home_with_rules() -> tempfile::TempDir {
    let home = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join(".config")).unwrap();
    fs::write(home.path().join(".config/attache-guard.toml"), "[[word]]\ntext = \"studio-mac\"\n").unwrap();
    home
}

fn wrapped_by_hook(home: &Path, command: &str) -> String {
    let out = hook(home, command);
    out.pointer("/overwrite/CommandLine").and_then(Value::as_str).unwrap_or_else(|| panic!("{out}")).to_owned()
}

#[test]
fn a_changed_rules_copy_refuses_and_the_command_never_runs() {
    let home = home_with_rules();
    let home = home.path();
    let wrapped = wrapped_by_hook(home, "touch \"$HOME/ran\"; echo studio-mac");
    let digest = wrapped.split("--rules-snapshot ").nth(1).unwrap().split(' ').next().unwrap();
    let copy = home.join(format!(".local/state/attache/guard/rules-{digest}.json"));
    let text = fs::read_to_string(&copy).unwrap();
    assert!(text.contains("\"enabled\":true"), "{text}");
    // What a model in the sandbox would write: the guard switched off.
    fs::write(&copy, text.replacen("\"enabled\":true", "\"enabled\":false", 1)).unwrap();

    let Some(out) = in_sandbox(home, &wrapped) else { return };
    assert_eq!(out.status.code(), Some(125), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(out.stdout.is_empty());
    assert!(!home.join("ran").exists(), "the command ran");
    fs::set_permissions(home.join(".config/attache-guard.toml"), fs::Permissions::from_mode(0o644)).unwrap();
}

#[test]
fn a_placeholder_gets_its_value_back_inside_and_the_output_is_masked_again() {
    let home = home_with_rules();
    let home = home.path();
    let mut child = cli(home).args(["guard", "mask"]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(b"studio-mac").unwrap();
    let placeholder = String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap();
    assert!(placeholder.starts_with("⟦word:"), "{placeholder}");

    let wrapped = wrapped_by_hook(home, &format!("test \"{placeholder}\" = studio-mac && echo restored {placeholder}"));
    let Some(out) = in_sandbox(home, &wrapped) else { return };
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(stdout.trim_end(), format!("restored {placeholder}"));
    fs::set_permissions(home.join(".config/attache-guard.toml"), fs::Permissions::from_mode(0o644)).unwrap();
}
