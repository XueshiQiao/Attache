//! Wiring the guard into each agent on this host, and saying whether it is.
//!
//! - Claude Code 2.1.287 and later: the mod in `guard-mod/`, written to
//!   `~/.local/share/attache/claude-guard/attache-guard` and named in the
//!   `env.CLAUDE_CODE_PLUGIN_DIRS` of `~/.claude/settings.json`, which Claude
//!   Code reads at every start (desktop-hosted sessions included). Older
//!   versions get `PreToolUse`/`PostToolUse` settings hooks instead.
//! - Codex: entries in `~/.codex/hooks.json`. Codex runs a new hook only
//!   after the person trusts it once in `/hooks`; nothing here can do that.
//! - agy: an `attache-guard` group in `~/.gemini/config/hooks.json`.
//!
//! Every file is the agent's and the person's, so only our own entries are
//! ever added or removed, and each file is copied aside before it changes.

use crate::fsutil::{write_atomic, write_through, Lock};
use crate::paths;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const MOD_PLUGIN: &str = include_str!("../../guard-mod/.claude-plugin/plugin.json");
const MOD_HOOKS: &str = include_str!("../../guard-mod/hooks/hooks.json");
const MOD_REGISTER: &str = include_str!("../../guard-mod/hooks/register.ts");

/// The first Claude Code with mods.
const MOD_MIN: (u32, u32, u32) = (2, 1, 287);

fn exe() -> String {
    std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "attache-cli".into())
}

fn hook_command(name: &str) -> String {
    format!("{} guard hook {name}", super::hooks::sh_quote(&exe()))
}

fn is_ours(command: &str) -> bool {
    [" guard hook claude-", " guard hook codex-", " guard hook agy-"].iter().any(|m| command.contains(m))
}

fn read_json(path: &Path) -> Result<Map<String, Value>, String> {
    match fs::read(path) {
        Ok(bytes) if bytes.iter().all(u8::is_ascii_whitespace) => Ok(Map::new()),
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
            Ok(Value::Object(m)) => Ok(m),
            _ => Err(format!("{} is not a JSON object; it was left as it is", path.display())),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn write_json(path: &Path, map: &Map<String, Value>) -> Result<(), String> {
    if path.exists() {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
        let backup = path.with_file_name(format!("{name}.attache-backup-{}", super::detect::now()));
        fs::copy(path, backup).map_err(|e| e.to_string())?;
    }
    let mut text = serde_json::to_string_pretty(map).map_err(|e| e.to_string())?;
    text.push('\n');
    write_through(path, text.as_bytes()).map_err(|e| e.to_string())
}

fn locked<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    let lock = Lock::acquire(&paths::state_dir().join("setup.lock"), Duration::from_secs(10)).map_err(|e| e.to_string())?;
    let _lock = lock.ok_or("another setup is running")?;
    f()
}

// ── Claude Code ───────────────────────────────────────────────────────────

fn mod_dir() -> PathBuf {
    paths::share_dir().join("claude-guard/attache-guard")
}

fn claude_settings() -> PathBuf {
    paths::claude_dir().join("settings.json")
}

fn claude_version() -> Option<(u32, u32, u32)> {
    let out = Command::new("/bin/sh").args(["-lc", "claude --version"]).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let v = text.split_whitespace().next()?;
    let mut parts = v.split('.').map(|p| p.parse::<u32>().ok());
    Some((parts.next()??, parts.next()??, parts.next()??))
}

fn plugin_dirs(settings: &Map<String, Value>) -> Vec<String> {
    settings
        .get("env")
        .and_then(|e| e.get("CLAUDE_CODE_PLUGIN_DIRS"))
        .and_then(Value::as_str)
        .map(|s| s.split(':').filter(|p| !p.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn set_plugin_dirs(settings: &mut Map<String, Value>, dirs: &[String]) {
    let env = settings.entry("env").or_insert_with(|| json!({}));
    if let Some(env) = env.as_object_mut() {
        if dirs.is_empty() {
            env.remove("CLAUDE_CODE_PLUGIN_DIRS");
        } else {
            env.insert("CLAUDE_CODE_PLUGIN_DIRS".into(), json!(dirs.join(":")));
        }
    }
    if settings.get("env").and_then(Value::as_object).is_some_and(Map::is_empty) {
        settings.remove("env");
    }
}

/// Removes our handlers from a Claude-style `hooks` object; true if any.
/// Only our own handlers go: a handler the person put in the same group
/// stays, and a group or an event is dropped only when we emptied it.
fn remove_our_hooks(hooks: &mut Map<String, Value>) -> bool {
    let ours = |h: &Value| h.get("command").and_then(Value::as_str).is_some_and(is_ours);
    let mut emptied: Vec<String> = Vec::new();
    let mut changed = false;
    for (event, groups) in hooks.iter_mut() {
        let Some(list) = groups.as_array_mut() else { continue };
        let before = list.len();
        list.retain_mut(|g| {
            let Some(handlers) = g.get_mut("hooks").and_then(Value::as_array_mut) else { return true };
            let had = handlers.len();
            handlers.retain(|h| !ours(h));
            if handlers.len() != had {
                changed = true;
                return !handlers.is_empty();
            }
            true
        });
        if list.is_empty() && before > 0 {
            emptied.push(event.clone());
        }
    }
    for event in emptied {
        hooks.remove(&event);
    }
    changed
}

fn add_hook(hooks: &mut Map<String, Value>, event: &str, matcher: Option<&str>, name: &str) {
    let mut group = json!({"hooks": [{"type": "command", "command": hook_command(name), "timeout": 30}]});
    if let Some(m) = matcher {
        group["matcher"] = json!(m);
    }
    let list = hooks.entry(event).or_insert_with(|| json!([]));
    if let Some(list) = list.as_array_mut() {
        list.push(group);
    }
}

fn claude_install() -> Result<String, String> {
    let version = claude_version();
    let use_mod = version.is_none_or(|v| v >= MOD_MIN);
    let path = claude_settings();
    let mut settings = read_json(&path)?;
    let dir = mod_dir().to_string_lossy().into_owned();
    let mut dirs = plugin_dirs(&settings);
    dirs.retain(|d| d != &dir);
    let mut hooks = settings.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    remove_our_hooks(&mut hooks);
    if use_mod {
        let d = mod_dir();
        fs::create_dir_all(d.join(".claude-plugin")).map_err(|e| e.to_string())?;
        fs::create_dir_all(d.join("hooks")).map_err(|e| e.to_string())?;
        write_atomic(&d.join(".claude-plugin/plugin.json"), MOD_PLUGIN.as_bytes()).map_err(|e| e.to_string())?;
        write_atomic(&d.join("hooks/hooks.json"), MOD_HOOKS.as_bytes()).map_err(|e| e.to_string())?;
        write_atomic(&d.join("hooks/register.ts"), MOD_REGISTER.as_bytes()).map_err(|e| e.to_string())?;
        dirs.push(dir);
    } else {
        add_hook(&mut hooks, "PreToolUse", Some("Bash|Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob|LS"), "claude-pre");
        add_hook(&mut hooks, "PostToolUse", Some("*"), "claude-post");
    }
    set_plugin_dirs(&mut settings, &dirs);
    if hooks.is_empty() {
        settings.remove("hooks");
    } else {
        settings.insert("hooks".into(), Value::Object(hooks));
    }
    crate::setup::write_settings(&path, &settings)?;
    Ok(if use_mod {
        "installed the mod; Claude Code sessions started from now on are protected (restart running ones)".into()
    } else {
        "this Claude Code has no mods, so hooks were installed: tool output is masked, but a prompt you type is not".into()
    })
}

fn claude_uninstall() -> Result<String, String> {
    let path = claude_settings();
    let mut settings = read_json(&path)?;
    let dir = mod_dir().to_string_lossy().into_owned();
    let mut dirs = plugin_dirs(&settings);
    let had = dirs.len();
    dirs.retain(|d| d != &dir);
    let mut changed = dirs.len() != had;
    set_plugin_dirs(&mut settings, &dirs);
    if let Some(hooks) = settings.get_mut("hooks").and_then(Value::as_object_mut) {
        changed |= remove_our_hooks(hooks);
        if hooks.is_empty() {
            settings.remove("hooks");
        }
    }
    if changed {
        crate::setup::write_settings(&path, &settings)?;
    }
    let _ = fs::remove_dir_all(mod_dir());
    Ok("removed from Claude Code; restart running sessions".into())
}

fn claude_status() -> Value {
    let settings = read_json(&claude_settings()).unwrap_or_default();
    let dir = mod_dir().to_string_lossy().into_owned();
    let named = plugin_dirs(&settings).contains(&dir);
    let on_disk = fs::read_to_string(mod_dir().join("hooks/register.ts")).ok();
    let hooks = settings
        .get("hooks")
        .is_some_and(|h| h.to_string().contains(" guard hook claude-"));
    let present = paths::claude_dir().exists();
    let (installed, how, current) = if named && on_disk.is_some() {
        (true, Some("mod"), on_disk.as_deref() == Some(MOD_REGISTER))
    } else if hooks {
        (true, Some("hooks"), true)
    } else {
        (false, None, false)
    };
    let note = match (installed, how, current) {
        (false, _, _) => "not protected: nothing filters this agent",
        (true, Some("mod"), false) => "an older version of the mod is installed; install again to update",
        (true, Some("mod"), true) => "prompts, replies and tool results are masked before they are stored or sent",
        _ => "hooks only: tool results are masked, prompts you type are not",
    };
    json!({"agent": "claude", "present": present, "installed": installed, "how": how, "current": current, "note": note})
}

// ── Codex ─────────────────────────────────────────────────────────────────

fn codex_dir() -> PathBuf {
    match std::env::var_os("CODEX_HOME") {
        Some(d) if !d.is_empty() && !cfg!(test) => PathBuf::from(d),
        _ => paths::home().join(".codex"),
    }
}

fn codex_install() -> Result<String, String> {
    let path = codex_dir().join("hooks.json");
    let mut root = read_json(&path)?;
    let mut hooks = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    remove_our_hooks(&mut hooks);
    add_hook(&mut hooks, "PreToolUse", Some("Bash"), "codex-pre");
    add_hook(&mut hooks, "PostToolUse", Some("Bash"), "codex-post");
    add_hook(&mut hooks, "UserPromptSubmit", None, "codex-prompt");
    root.insert("hooks".into(), Value::Object(hooks));
    fs::create_dir_all(codex_dir()).map_err(|e| e.to_string())?;
    write_json(&path, &root)?;
    Ok("installed; Codex runs new hooks only after you trust them once: type /hooks in Codex".into())
}

fn codex_uninstall() -> Result<String, String> {
    let path = codex_dir().join("hooks.json");
    let mut root = read_json(&path)?;
    let changed = root.get_mut("hooks").and_then(Value::as_object_mut).is_some_and(remove_our_hooks);
    if changed {
        write_json(&path, &root)?;
    }
    Ok("removed from Codex".into())
}

fn codex_status() -> Value {
    let root = read_json(&codex_dir().join("hooks.json")).unwrap_or_default();
    let installed = root.get("hooks").is_some_and(|h| h.to_string().contains(" guard hook codex-"));
    let note = if installed {
        "commands run through the guard where Codex asks no approval; elsewhere output is masked after the fact and stays raw in Codex's own session file; a message with private values is stopped"
    } else {
        "not protected: nothing filters this agent"
    };
    json!({"agent": "codex", "present": codex_dir().exists(), "installed": installed, "how": installed.then_some("hooks"), "current": true, "note": note})
}

// ── agy ───────────────────────────────────────────────────────────────────

const AGY_GROUP: &str = "attache-guard";

fn agy_hooks() -> PathBuf {
    paths::home().join(".gemini/config/hooks.json")
}

fn agy_install() -> Result<String, String> {
    let path = agy_hooks();
    let mut root = read_json(&path)?;
    root.insert(
        AGY_GROUP.into(),
        json!({"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": hook_command("agy-pre"), "timeout": 30}]}]}),
    );
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    write_json(&path, &root)?;
    Ok("installed; agy picks it up in new sessions".into())
}

fn agy_uninstall() -> Result<String, String> {
    let path = agy_hooks();
    let mut root = read_json(&path)?;
    if root.remove(AGY_GROUP).is_some() {
        write_json(&path, &root)?;
    }
    Ok("removed from agy".into())
}

fn agy_status() -> Value {
    let root = read_json(&agy_hooks()).unwrap_or_default();
    let installed = root.contains_key(AGY_GROUP);
    let note = if installed {
        "commands run through the guard; a file with private values cannot be read directly; prompts you type are not masked"
    } else {
        "not protected: nothing filters this agent"
    };
    json!({"agent": "agy", "present": paths::home().join(".gemini").exists(), "installed": installed, "how": installed.then_some("hooks"), "current": true, "note": note})
}

// ──────────────────────────────────────────────────────────────────────────

pub fn install(agent: &str) -> Result<String, String> {
    locked(|| match agent {
        "claude" => claude_install(),
        "codex" => codex_install(),
        "agy" => agy_install(),
        _ => Err(format!("unknown agent {agent}")),
    })
}

pub fn uninstall(agent: &str) -> Result<String, String> {
    locked(|| match agent {
        "claude" => claude_uninstall(),
        "codex" => codex_uninstall(),
        "agy" => agy_uninstall(),
        _ => Err(format!("unknown agent {agent}")),
    })
}

pub fn status() -> Vec<Value> {
    vec![claude_status(), codex_status(), agy_status()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_home<T>(f: impl FnOnce(&Path) -> T) -> T {
        let dir = tempfile::tempdir().unwrap();
        paths::TEST_HOME.with(|h| *h.borrow_mut() = Some(dir.path().to_path_buf()));
        let out = f(dir.path());
        paths::TEST_HOME.with(|h| *h.borrow_mut() = None);
        out
    }

    #[test]
    fn codex_install_keeps_the_persons_hooks_and_removes_only_ours() {
        with_home(|home| {
            let path = home.join(".codex/hooks.json");
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            let theirs = json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify-me"}]}]}});
            fs::write(&path, theirs.to_string()).unwrap();
            codex_install().unwrap();
            codex_install().unwrap();
            let root = read_json(&path).unwrap();
            assert_eq!(root["hooks"]["PreToolUse"].as_array().unwrap().len(), 1, "installing twice adds once");
            assert!(codex_status()["installed"].as_bool().unwrap());
            codex_uninstall().unwrap();
            assert_eq!(Value::Object(read_json(&path).unwrap()), theirs);
        });
    }

    #[test]
    fn a_persons_handler_beside_ours_and_their_empty_events_stay() {
        let mut hooks = json!({
            "PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": "'/x/attache-cli' guard hook codex-pre"},
                {"type": "command", "command": "their-own-check"}
            ]}],
            "Stop": []
        });
        let map = hooks.as_object_mut().unwrap();
        assert!(remove_our_hooks(map));
        assert_eq!(Value::Object(map.clone()), json!({
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "their-own-check"}]}],
            "Stop": []
        }));
    }

    #[test]
    fn a_linked_config_stays_a_link() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("dotfiles-hooks.json");
        let link = dir.path().join("hooks.json");
        fs::write(&real, "{}").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let mut m = Map::new();
        m.insert("x".into(), json!(1));
        write_json(&link, &m).unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert!(fs::read_to_string(&real).unwrap().contains("\"x\": 1"));
    }

    #[test]
    fn agy_group_comes_and_goes() {
        with_home(|home| {
            let path = home.join(".gemini/config/hooks.json");
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, r#"{"attache-status": {"Stop": []}}"#).unwrap();
            agy_install().unwrap();
            assert!(agy_status()["installed"].as_bool().unwrap());
            agy_uninstall().unwrap();
            assert_eq!(Value::Object(read_json(&path).unwrap()), json!({"attache-status": {"Stop": []}}));
        });
    }

    #[test]
    fn plugin_dirs_keep_the_persons_own() {
        let mut s = Map::new();
        s.insert("env".into(), json!({"CLAUDE_CODE_PLUGIN_DIRS": "/a:/b", "X": "1"}));
        let mut dirs = plugin_dirs(&s);
        dirs.push("/ours".into());
        set_plugin_dirs(&mut s, &dirs);
        assert_eq!(s["env"]["CLAUDE_CODE_PLUGIN_DIRS"], "/a:/b:/ours");
        set_plugin_dirs(&mut s, &[]);
        assert_eq!(s["env"], json!({"X": "1"}));
    }
}
