//! `project`: saved, listed, opened and removed against a real tmux server
//! of its own (`-L` on every command) and a home folder of its own. The
//! server's shell is bash with a startup file that defines an alias, because
//! an alias is the thing a saved command most often is.

use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{Duration, Instant};

fn tmux_bin() -> Option<PathBuf> {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
}

fn b64(text: &str) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in text.as_bytes().chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() { T[(n >> (18 - 6 * i)) as usize & 63] as char } else { '=' });
        }
    }
    out
}

struct Server {
    tmux: PathBuf,
    socket: String,
    home: tempfile::TempDir,
}

impl Server {
    fn start(tmux: PathBuf, name: &str) -> Server {
        let home = tempfile::tempdir().unwrap();
        // Both files: bash reads one as a login shell and the other as an
        // interactive one, and `open` asks for a shell that is both.
        for rc in [".bash_profile", ".bashrc"] {
            fs::write(home.path().join(rc), "alias wsalias='touch'\nPS1='ready> '\n").unwrap();
        }
        let socket = format!("attache-cli-ws-{name}-{}", std::process::id());
        let s = Server { tmux, socket, home };
        let ok = Command::new(&s.tmux)
            .args(["-L", &s.socket, "-f", "/dev/null", "new-session", "-d", "-s", "probe", "-x", "120", "-y", "30", "cat"])
            .env("HOME", s.home.path())
            .status()
            .unwrap()
            .success();
        assert!(ok);
        s.tmux(&["set-option", "-g", "default-shell", "/bin/bash"]);
        s
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = Command::new(&self.tmux).arg("-u").arg("-L").arg(&self.socket).args(args).output().unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
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
        serde_json::from_slice(&o.stdout).unwrap_or_else(|_| {
            panic!("{args:?}: {} {}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
        })
    }

    fn save(&self, name: &str, path: &str, command: &str) -> Value {
        self.json(&["project", "save", "--name", &b64(name), "--path", &b64(path), "--command", &b64(command)])
    }

    fn list(&self) -> Vec<Value> {
        String::from_utf8_lossy(&self.cli(&["projects"]).stdout)
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .filter(|v| v.get("id").is_some())
            .collect()
    }

    fn file(&self) -> String {
        fs::read_to_string(self.home.path().join(".config/attache-projects.toml")).unwrap()
    }

    fn session(&self) -> String {
        self.tmux(&["display-message", "-p", "-t", "probe", "#{session_id}"])
    }

    /// Waits until `what` holds, or fails saying what the pane shows.
    fn wait(&self, pane: &str, what: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !what() {
            assert!(Instant::now() < deadline, "screen:\n{}", self.tmux(&["capture-pane", "-p", "-t", pane]));
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux).args(["-L", &self.socket, "kill-server"]).output();
    }
}

#[test]
fn a_project_is_saved_listed_edited_and_removed() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "file");
    assert!(s.list().is_empty());

    let a = s.save("  Paste\tPaw ", "~/code", "cyolo");
    assert_eq!(a["saved"], true);
    assert_eq!(a["name"], "Paste Paw");
    assert_eq!(a["exists"], false);
    let b = s.save("B", "/tmp", "");
    let (ida, idb) = (a["id"].as_str().unwrap(), b["id"].as_str().unwrap());
    assert_ne!(ida, idb);
    assert_eq!(s.list().iter().map(|w| w["name"].as_str().unwrap().to_owned()).collect::<Vec<_>>(), ["Paste Paw", "B"]);

    // What the person adds by hand stays through an edit.
    let by_hand = s.file().replace("command = \"cyolo\"", "command = \"cyolo\"  # my alias\ncolour = \"red\"");
    fs::write(s.home.path().join(".config/attache-projects.toml"), &by_hand).unwrap();
    let e = s.json(&["project", "save", "--id", ida, "--name", &b64("Paw"), "--path", &b64("~/code"), "--command", &b64("claude -c")]);
    assert_eq!(e["id"], ida);
    assert_eq!(s.file(), by_hand.replace("\"Paste Paw\"", "\"Paw\"").replace("\"cyolo\"", "\"claude -c\""));

    for (name, path, command) in [("", "/tmp", ""), ("N", "relative/x", ""), ("N", "/tmp", "a\nb")] {
        let bad = s.save(name, path, command);
        assert_eq!(bad["saved"], false, "{name:?} {path:?} {command:?}");
    }
    assert_eq!(s.list().len(), 2);

    assert_eq!(s.json(&["project", "remove", ida])["removed"], true);
    assert_eq!(s.json(&["project", "remove", ida])["removed"], false);
    assert_eq!(s.list().len(), 1);
    assert!(s.file().contains("colour = \"red\"") == false && s.file().contains("name = \"B\""));
}

#[test]
fn a_link_to_a_dotfiles_copy_stays_a_link() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "link");
    let real = s.home.path().join("dotfiles/projects.toml");
    fs::create_dir_all(real.parent().unwrap()).unwrap();
    fs::write(&real, "").unwrap();
    let link = s.home.path().join(".config/attache-projects.toml");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert_eq!(s.save("A", "/tmp", "")["saved"], true);
    assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    assert!(fs::read_to_string(&real).unwrap().contains("name = \"A\""));
}

#[test]
fn opening_makes_a_window_in_the_folder_running_the_command() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "open");
    let session = s.session();
    // A folder whose name tmux would expand as a format, and a quote.
    let dir = s.home.path().join("it's #{pane_id} dir");
    fs::create_dir_all(&dir).unwrap();
    let dir = fs::canonicalize(&dir).unwrap();
    let path = dir.to_str().unwrap();

    // The command is an alias, with an argument that needs its quotes.
    let id = s.save("W #{pane_id}", path, "wsalias 'ran here'")["id"].as_str().unwrap().to_owned();
    let o = s.json(&["project", "open", &id, "--session", &session]);
    assert_eq!(o["opened"], true, "{o}");
    let (window, pane) = (o["window"].as_str().unwrap(), o["pane"].as_str().unwrap());
    s.wait(pane, || dir.join("ran here").exists());
    // The window is named as saved, selected, and in the folder.
    assert_eq!(s.tmux(&["display-message", "-p", "-t", window, "#{window_name}|#{window_active}"]), "W #{pane_id}|1");
    // The command ended and a shell is left, in the folder.
    s.wait(pane, || s.tmux(&["capture-pane", "-p", "-t", pane]).contains("ready>"));
    assert_eq!(s.tmux(&["display-message", "-p", "-t", pane, "#{pane_dead}|#{pane_current_path}"]), format!("0|{path}"));

    // Opened again, it is another window.
    let again = s.json(&["project", "open", &id, "--session", &session]);
    assert_ne!(again["window"], o["window"]);

    // A command the shell cannot parse still leaves a shell to read why.
    let broken = s.save("Broken", path, "if then (")["id"].as_str().unwrap().to_owned();
    let o = s.json(&["project", "open", &broken, "--session", &session]);
    let pane = o["pane"].as_str().unwrap().to_owned();
    s.wait(&pane, || s.tmux(&["capture-pane", "-p", "-t", &pane]).contains("ready>"));
    assert!(s.tmux(&["capture-pane", "-p", "-t", &pane]).contains("syntax error"));

    // No command: tmux's own new window, nothing run in it.
    let plain = s.save("Plain", path, "")["id"].as_str().unwrap().to_owned();
    let o = s.json(&["project", "open", &plain, "--session", &session]);
    let pane = o["pane"].as_str().unwrap().to_owned();
    s.wait(&pane, || s.tmux(&["display-message", "-p", "-t", &pane, "#{pane_current_path}"]) == path);

    // A folder that is gone, a project that is gone, a session that is gone.
    let gone = s.save("Gone", "/nonexistent/attache", "")["id"].as_str().unwrap().to_owned();
    let before = s.tmux(&["list-windows", "-a"]).lines().count();
    for args in [
        vec!["project", "open", gone.as_str(), "--session", session.as_str()],
        vec!["project", "open", "nosuchid", "--session", session.as_str()],
        vec!["project", "open", plain.as_str(), "--session", "$999"],
    ] {
        let o = s.json(&args);
        assert_eq!(o["opened"], false, "{args:?}");
        assert!(!o["why"].as_str().unwrap().is_empty(), "{args:?}");
    }
    assert_eq!(s.tmux(&["list-windows", "-a"]).lines().count(), before);
    // Anything that is not a session id is refused before tmux sees it.
    assert_eq!(s.cli(&["project", "open", &plain, "--session", "probe"]).status.code(), Some(2));
}

#[test]
fn a_draft_is_the_windows_name_and_folder() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "draft");
    let dir = fs::canonicalize(s.home.path()).unwrap();
    let window = s.tmux(&["new-window", "-P", "-F", "#{window_id}", "-t", "probe:", "-n", "notes", "-c", dir.to_str().unwrap(), "cat"]);
    let d = s.json(&["project", "draft", &window]);
    assert_eq!(d["draft"], true);
    assert_eq!(d["name"], "notes");
    assert_eq!(d["path"], dir.to_str().unwrap());
    assert_eq!(d["command"], "");
    assert_eq!(s.json(&["project", "draft", "@999"])["draft"], false);
}

#[test]
fn the_commands_list_is_set_and_read_and_comes_with_the_projects() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "commands");
    assert_eq!(s.json(&["project", "commands"])["commands"], serde_json::json!([]));
    assert_eq!(s.save("A", "/tmp", "cyolo")["saved"], true);
    // No list written yet: the commands the saved projects run.
    assert_eq!(s.json(&["project", "commands"])["commands"], serde_json::json!(["cyolo"]));
    let set = s.json(&["project", "commands", "--set", &b64("cyolo\n gemini \n\ncyolo\nclaude --model 'x y'\n")]);
    assert_eq!(set["commands"], serde_json::json!(["cyolo", "gemini", "claude --model 'x y'"]));
    assert_eq!(s.json(&["project", "commands"])["commands"], set["commands"]);
    // The project saved before the list was there is still there.
    assert_eq!(s.list().len(), 1);
    let all = String::from_utf8_lossy(&s.cli(&["projects"]).stdout).into_owned();
    let last: Value = serde_json::from_str(all.lines().last().unwrap()).unwrap();
    assert_eq!(last["commands"], set["commands"]);
    // Written over several lines by hand: said, so a client does not offer
    // to edit what it would be refused for.
    let path = s.home.path().join(".config/attache-projects.toml");
    let by_hand = s.file().replace("commands = [\"cyolo\", \"gemini\", \"claude --model 'x y'\"]", "commands = [\n  \"cyolo\",\n]");
    fs::write(&path, &by_hand).unwrap();
    let all = String::from_utf8_lossy(&s.cli(&["projects"]).stdout).into_owned();
    let last: Value = serde_json::from_str(all.lines().last().unwrap()).unwrap();
    assert!(last["commands_why"].as_str().is_some_and(|w| !w.is_empty()));
    assert_eq!(s.json(&["project", "commands", "--set", &b64("x")])["commands"], false);
    assert_eq!(s.file(), by_hand);
    fs::write(&path, by_hand.replace("commands = [\n  \"cyolo\",\n]", "commands = [\"cyolo\"]")).unwrap();
    // Emptied again.
    assert_eq!(s.json(&["project", "commands", "--set", "="])["commands"], serde_json::json!([]));
}

#[test]
fn the_file_from_before_the_rename_is_read_and_then_moved() {
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "rename");
    let config = s.home.path().join(".config");
    fs::create_dir_all(&config).unwrap();
    let old = config.join("attache-workspaces.toml");
    fs::write(&old, "# mine\n[[workspace]]\nid = \"abcd1234\"\nname = \"Old\"\npath = \"/tmp\"\ncommand = \"cyolo\"\n").unwrap();
    // Reading shows it and moves nothing.
    assert_eq!(s.list()[0]["name"], "Old");
    assert!(old.exists() && !config.join("attache-projects.toml").exists());
    // The first change writes the new file, with the old one's contents, and
    // the old one goes.
    assert_eq!(s.save("New", "/tmp", "")["saved"], true);
    assert!(!old.exists());
    assert!(s.file().starts_with("# mine\n[[project]]\nid = \"abcd1234\"\nname = \"Old\""));
    assert_eq!(s.list().len(), 2);

    // An old file that turns up beside the new one was never read, so it
    // is not this program's to delete.
    fs::write(&old, "[[workspace]]\npath = \"/kept\"\n").unwrap();
    assert_eq!(s.save("Third", "/tmp", "")["saved"], true);
    assert!(old.exists());
    assert_eq!(s.list().len(), 3);
}

#[test]
fn an_old_file_linked_into_dotfiles_moves_inside_the_dotfiles() {
    use std::os::unix::fs::PermissionsExt;
    let Some(tmux) = tmux_bin() else { return };
    let s = Server::start(tmux, "relink");
    let config = s.home.path().join(".config");
    let dotfiles = s.home.path().join("dotfiles");
    fs::create_dir_all(&config).unwrap();
    fs::create_dir_all(&dotfiles).unwrap();
    let real_old = dotfiles.join("attache-workspaces.toml");
    fs::write(&real_old, "[[workspace]]\nid = \"abcd1234\"\npath = \"/tmp\"\n").unwrap();
    fs::set_permissions(&real_old, fs::Permissions::from_mode(0o600)).unwrap();
    std::os::unix::fs::symlink(&real_old, config.join("attache-workspaces.toml")).unwrap();

    assert_eq!(s.save("New", "/tmp", "")["saved"], true);
    // The new file is in the dotfiles folder, private as the old one was,
    // with a link to it where the program looks.
    let real_new = dotfiles.join("attache-projects.toml");
    assert!(fs::read_to_string(&real_new).unwrap().contains("name = \"New\""));
    assert_eq!(fs::metadata(&real_new).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(fs::symlink_metadata(config.join("attache-projects.toml")).unwrap().file_type().is_symlink());
    // The link is gone; the file in the person's repository is untouched.
    assert!(fs::symlink_metadata(config.join("attache-workspaces.toml")).is_err());
    assert!(real_old.exists());
    assert_eq!(s.list().len(), 2);
    // And the next change goes through the link.
    assert_eq!(s.save("Again", "/tmp", "")["saved"], true);
    assert!(fs::read_to_string(&real_new).unwrap().contains("name = \"Again\""));
}
