//! `attache-cli agents [--pane %N]`: every agent in tmux, one JSON object a
//! line, from what the agents write for themselves and nothing any other
//! program installed.
//!
//! Which pane holds which agent comes from the process table: tmux gives
//! each pane's first process, and the agent is the nearest process under it
//! that a provider recognises. Claude Code also writes its pane into its
//! session file (`"tmux": "Dev:@4.%145"`), but that field is its own
//! business and can go in any release; the process tree cannot. Nearest
//! first also settles nesting: Claude running `agy -p` in a tool call is
//! still a Claude pane.
//!
//! Done and Idle are both an agent with nothing to do. Done means its last
//! turn ended after the conversation was last looked at (`seen`); Idle, that
//! it was looked at since, or never did anything.

use crate::fsutil::{safe_id, write_atomic, Lock};
use crate::host::{children, descendants, Host, Pane, Process};
use crate::paths;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Working,
    NeedsYou,
    Done,
    Idle,
    /// Running, but nothing it writes says what it is doing (yet).
    Unknown,
}

impl State {
    pub fn word(self) -> &'static str {
        match self {
            State::Working => "working",
            State::NeedsYou => "needs_you",
            State::Done => "done",
            State::Idle => "idle",
            State::Unknown => "unknown",
        }
    }
}

/// What one agent in one pane is doing.
#[derive(Clone, Debug)]
pub struct Agent {
    pub pane: Pane,
    pub pid: Option<u32>,
    pub kind: &'static str,
    pub state: State,
    /// When the state began, epoch seconds, when known.
    pub since: Option<u64>,
    pub conversation: Option<String>,
    pub transcript: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    /// When its last turn ended, if it has finished one: the half of Done
    /// that comes from the agent.
    pub turn_ended: Option<u64>,
    /// The pane's title when the person renamed it (`rename`), so a client
    /// knows the title is theirs and can offer to give it back.
    pub name: Option<String>,
}

impl Agent {
    fn new(pane: &Pane, pid: Option<u32>, kind: &'static str) -> Agent {
        Agent {
            pane: pane.clone(),
            pid,
            kind,
            state: State::Unknown,
            since: None,
            conversation: None,
            transcript: None,
            cwd: None,
            model: None,
            turn_ended: None,
            name: None,
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "pane": self.pane.id,
            "pid": self.pid,
            "session": self.pane.session_name,
            "window": self.pane.window_id,
            "window_index": self.pane.window_index,
            "window_name": self.pane.window_name,
            "command": self.pane.command,
            "path": self.pane.path,
            "title": self.pane.title,
            "kind": self.kind,
            "state": self.state.word(),
            "since": self.since,
            "conversation": self.conversation,
            "transcript": self.transcript,
            "cwd": self.cwd,
            "model": self.model,
            "name": self.name,
        })
    }
}

/// What every provider may look at, read once per run.
pub struct Context<'a> {
    pub host: &'a dyn Host,
    names: HashMap<u32, String>,
    children: HashMap<u32, Vec<u32>>,
    claude: ClaudeSessions,
    agy_locks: Option<HashMap<u32, Vec<String>>>,
    screens: HashMap<String, Vec<String>>,
}

impl<'a> Context<'a> {
    pub fn new(host: &'a dyn Host) -> Context<'a> {
        let processes: Vec<Process> = host.processes();
        Context {
            host,
            names: processes.iter().map(|p| (p.pid, p.name.clone())).collect(),
            children: children(&processes),
            claude: ClaudeSessions::read(host),
            agy_locks: None,
            screens: HashMap::new(),
        }
    }

    /// The pane's screen, read ahead of time when many are needed.
    pub fn screen(&self, pane: &str) -> Vec<String> {
        self.screens
            .get(pane)
            .cloned()
            .unwrap_or_else(|| self.host.screen(pane))
    }

    /// Reads these panes' screens at once: one `capture-pane` is a process
    /// and a round trip to the server, and a dozen agy panes one after
    /// another took 0.4 s here.
    fn prefetch_screens(&mut self, panes: &[String]) {
        let host = self.host;
        let read: Vec<(String, Vec<String>)> = std::thread::scope(|s| {
            let jobs: Vec<_> = panes
                .iter()
                .map(|p| s.spawn(move || (p.clone(), host.screen(p))))
                .collect();
            jobs.into_iter().filter_map(|j| j.join().ok()).collect()
        });
        self.screens.extend(read);
    }
}

/// One coding agent product. A new agent is a new implementation and
/// nothing else changes.
pub trait Provider {
    fn kind(&self) -> &'static str;
    /// Whether `describe` reads the pane's screen.
    fn reads_screen(&self) -> bool {
        false
    }
    /// Whether this process is this agent.
    fn is_process(&self, pid: u32, name: &str, ctx: &Context) -> bool;
    /// Whether a pane whose foreground command reads `command` is this agent,
    /// for when no process under the pane was recognised.
    fn is_command(&self, command: &str) -> bool;
    fn describe(&self, pane: &Pane, pid: Option<u32>, ctx: &mut Context) -> Agent;
}

pub fn providers() -> Vec<Box<dyn Provider>> {
    vec![
        Box::new(Claude),
        Box::new(Agy),
        Box::new(Recognised {
            kind: "codex",
            names: &["codex"],
        }),
        Box::new(Recognised {
            kind: "grok",
            names: &["grok"],
        }),
        Box::new(Recognised {
            kind: "gemini",
            names: &["gemini"],
        }),
    ]
}

/// The agents in tmux, or in pane `only`.
pub fn discover(host: &dyn Host, only: Option<&str>) -> Vec<Agent> {
    let providers = providers();
    let mut ctx = Context::new(host);
    let mut found = Vec::new();
    for pane in host.panes() {
        if only.is_some_and(|p| p != pane.id) {
            continue;
        }
        let by_process = descendants(pane.pid, &ctx.children)
            .into_iter()
            .find_map(|pid| {
                let name = ctx.names.get(&pid).map(String::as_str).unwrap_or("");
                providers
                    .iter()
                    .find(|p| p.is_process(pid, name, &ctx))
                    .map(|p| (p, Some(pid)))
            });
        let by_command = || {
            providers
                .iter()
                .find(|p| p.is_command(&pane.command))
                .map(|p| (p, None))
        };
        if let Some((provider, pid)) = by_process.or_else(by_command) {
            found.push((pane, provider, pid));
        }
    }
    let screens: Vec<String> = found
        .iter()
        .filter(|(_, p, _)| p.reads_screen())
        .map(|(pane, _, _)| pane.id.clone())
        .collect();
    if screens.len() > 1 {
        ctx.prefetch_screens(&screens);
    }
    found
        .into_iter()
        .map(|(pane, provider, pid)| {
            let mut agent = provider.describe(&pane, pid, &mut ctx);
            settle_done(&mut agent);
            agent.name = agent.pane.renamed.then(|| agent.pane.title.clone());
            agent
        })
        .collect()
}

/// Done until looked at: an agent with nothing to do whose last turn ended
/// after its conversation was last seen.
fn settle_done(agent: &mut Agent) {
    if agent.state != State::Idle {
        return;
    }
    let (Some(ended), Some(conversation)) = (agent.turn_ended, agent.conversation.as_deref())
    else {
        return;
    };
    if ended > seen_at(agent.kind, conversation).unwrap_or(0) {
        agent.state = State::Done;
    }
}

fn seen_path(kind: &str, conversation: &str) -> PathBuf {
    paths::state_dir()
        .join(kind)
        .join(conversation)
        .join("seen.json")
}

pub fn seen_at(kind: &str, conversation: &str) -> Option<u64> {
    let v: Value = serde_json::from_slice(&fs::read(seen_path(kind, conversation)).ok()?).ok()?;
    v.get("at")?.as_u64()
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The longest name kept, in characters: a list row shows a line of it.
const NAME_MAX: usize = 200;

/// `attache-cli rename <%pane> --name <base64>`: names the pane, and so
/// the agent in it, everywhere at once — the phone, the desktop, every
/// terminal attached to tmux — by making the name the pane's own title.
/// An empty name gives the title back to the program in the pane.
///
/// The title is otherwise the program's: Claude writes "✳ <its title for
/// the conversation>" there and keeps rewriting the glyph as it works, so a
/// plain `select-pane -T` would last seconds. Turning the pane's
/// `allow-set-title` off first stops that (measured on tmux 3.6a: with it
/// off, a program's title escape no longer changes the title, and unset, it
/// does again). What it costs is only the glyph: Claude names a conversation
/// once and never again — across all 153 titled conversations on the
/// owner's Mac (2026-11-08) not one had a second title. `@attache_renamed`
/// marks the panes this program renamed, so `agents` can say which titles
/// are the person's, and a reset touches only those.
///
/// The name comes base64-encoded, as `input`'s text does, because it
/// arrives on an SSH command line. Prints `{"renamed":true,"pane","name"}`
/// (`name` null after a reset) or `{"renamed":false,"why"}`.
pub fn run_rename(args: &[String]) -> i32 {
    let usage = || {
        eprintln!("Usage: attache-cli rename <%pane> --name <base64>");
        2
    };
    let [pane, flag, b64] = args else {
        return usage();
    };
    if flag != "--name" || !crate::screen::is_pane(pane) {
        return usage();
    }
    let Some(name) = crate::input::decode(b64).and_then(|b| String::from_utf8(b).ok()) else {
        eprintln!("attache-cli rename: the name is not base64 of UTF-8 text");
        return 2;
    };
    let name = tidy_name(&name);
    let answer = if name.is_empty() {
        reset_title(pane)
    } else {
        set_title(pane, &name)
    };
    let ok = answer.is_ok();
    println!(
        "{}",
        match answer {
            Ok(()) => json!({ "renamed": true, "pane": pane, "name": (!name.is_empty()).then_some(&name) }),
            Err(why) => json!({ "renamed": false, "pane": pane, "why": why }),
        }
    );
    if ok {
        0
    } else {
        1
    }
}

/// One line, without the control characters a terminal would act on, and
/// no longer than [`NAME_MAX`].
pub fn tidy_name(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(NAME_MAX)
        .collect()
}

/// `select-pane -T` expands its argument as a tmux format, and in a format
/// `#(…)` runs a shell command: measured on 3.6a, a title of
/// `#{pane_id}` came out as `%0` and `#(echo hi)` was run. `##` is a
/// literal `#`, so doubling every one makes any name come out as typed —
/// including `#(touch …)`, which then runs nothing.
pub fn tmux_literal(text: &str) -> String {
    text.replace('#', "##")
}

/// The three steps go to tmux as one command line (`;` between them), which
/// tmux runs in order with nothing else in between: run one by one, an
/// `agents --watch` could read the marker before the title and take the old
/// title for the person's, and a step that failed half way would leave the
/// pane locked with no marker for a reset to find. With `allow-set-title`
/// first, a tmux without it (an option this program learned on 3.6a, said
/// to have arrived in 3.3) fails the line before anything changes.
fn set_title(pane: &str, name: &str) -> Result<(), &'static str> {
    let title = tmux_literal(name);
    crate::tmux::run(&[
        "set-option", "-p", "-t", pane, "allow-set-title", "off", ";",
        "set-option", "-p", "-t", pane, "@attache_renamed", "1", ";",
        "select-pane", "-t", pane, "-T", &title,
    ])
    .map(|_| ())
    .ok_or("tmux refused it (no allow-set-title before 3.3, or no such pane)")
}

/// Gives the title back. Claude would only write its own again at its next
/// state change, so its title for the conversation (the last `ai-title` in
/// its transcript) is put back at once; anything else gets an empty title,
/// which clients show as the window's name until the program writes one.
fn reset_title(pane: &str) -> Result<(), &'static str> {
    // Asked of tmux itself, not of `agents`: a pane can be renamed with no
    // agent found in it (one that has exited, or a plain shell).
    let marker = crate::tmux::run(&["display-message", "-p", "-t", pane, "#{@attache_renamed}"])
        .ok_or("no such pane")?;
    // A pane this program did not rename keeps whatever it has.
    if String::from_utf8_lossy(&marker.stdout).trim().is_empty() {
        return Ok(());
    }
    let agent = discover(&crate::host::RealHost, Some(pane)).into_iter().next();
    let own = agent
        .as_ref()
        .filter(|a| a.kind == "claude")
        .and_then(|a| a.transcript.as_deref())
        .and_then(claude_ai_title)
        .map(|t| format!("\u{2733} {t}"))
        .unwrap_or_default();
    // The title first and the lock last, in one line: unlocked first, the
    // program could write its own title and then have it overwritten here.
    let title = tmux_literal(&own);
    crate::tmux::run(&[
        "select-pane", "-t", pane, "-T", &title, ";",
        "set-option", "-p", "-t", pane, "-u", "@attache_renamed", ";",
        "set-option", "-p", "-t", pane, "-u", "allow-set-title",
    ])
    .map(|_| ())
    .ok_or("tmux")
}

/// The last title Claude gave the conversation, from its transcript's
/// `ai-title` records, read a line at a time: a long transcript runs to
/// tens of megabytes.
fn claude_ai_title(transcript: &str) -> Option<String> {
    use std::io::BufRead;
    let file = fs::File::open(transcript).ok()?;
    let mut last = None;
    for line in std::io::BufReader::new(file).lines().map_while(Result::ok) {
        if !line.contains("\"ai-title\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v.get("type").and_then(Value::as_str) == Some("ai-title") {
            if let Some(t) = v.get("aiTitle").and_then(Value::as_str).filter(|t| !t.trim().is_empty()) {
                last = Some(t.to_owned());
            }
        }
    }
    last
}

/// `attache-cli seen <kind> <conversation>`: the person has looked at it.
/// The phone and the tablet can both say so at once; the later time stays.
pub fn run_seen(args: &[String]) -> i32 {
    let (Some(kind), Some(conversation)) = (args.first(), args.get(1)) else {
        eprintln!("Usage: attache-cli seen <kind> <conversation>");
        return 2;
    };
    if !safe_id(kind) || !safe_id(conversation) {
        eprintln!("attache-cli seen: not an id");
        return 2;
    }
    let path = seen_path(kind, conversation);
    let Ok(Some(_lock)) = Lock::acquire(&path.with_file_name("seen.lock"), Duration::from_secs(2))
    else {
        return 1;
    };
    let at = now().max(seen_at(kind, conversation).unwrap_or(0));
    if write_atomic(&path, json!({ "at": at }).to_string().as_bytes()).is_err() {
        return 1;
    }
    println!(
        "{}",
        json!({ "kind": kind, "conversation": conversation, "seen": at })
    );
    0
}

/// `attache-cli agents [--pane %N]`.
pub fn run(args: &[String], host: &dyn Host) -> i32 {
    let (watch, rest) = match args.split_first() {
        Some((w, rest)) if w == "--watch" => (true, rest),
        _ => (false, args),
    };
    let only = match rest {
        [] => None,
        [flag, pane] if flag == "--pane" && crate::screen::is_pane(pane) => Some(pane.as_str()),
        _ => {
            eprintln!("Usage: attache-cli agents [--watch] [--pane %N]");
            return 2;
        }
    };
    if watch {
        return run_watch(host, only);
    }
    for agent in discover(host, only) {
        println!("{}", agent.to_json());
    }
    0
}

/// `agents --watch [--pane %N]`: the same agents, kept up to date, so no
/// client has to ask again and again over a slow link.
///
/// ```text
/// {"t":"agents","agents":[…]}     every agent (or the pane's), whenever any changed
/// {"t":"screen",…}                with --pane: what `screen` reads, whenever it changed
/// ```
///
/// The first of each is sent at once. Like `follow`, it runs until stdin
/// ends (the SSH channel closed) and writes a byte to stderr every 15 s to
/// find a channel that went without saying so. The host does the asking:
/// a list every 1.5 s, one pane every 0.5 s, which on this machine is a
/// `ps`, a `list-panes` and a read of Claude's session folder each time.
fn run_watch(host: &dyn Host, only: Option<&str>) -> i32 {
    use std::io::Write;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    let gone = Arc::new(AtomicBool::new(false));
    crate::follow::watch_stdin(gone.clone());
    let mut out = crate::follow::Out::default();
    let tick = if only.is_some() {
        Duration::from_millis(500)
    } else {
        Duration::from_millis(1500)
    };
    let mut last_agents: Option<String> = None;
    let mut last_screen: Option<String> = None;
    let mut beat = std::time::Instant::now();
    loop {
        let agents = discover(host, only);
        let list = Value::Array(agents.iter().map(Agent::to_json).collect());
        let text = list.to_string();
        if last_agents.as_deref() != Some(text.as_str()) {
            out.send(json!({ "t": "agents", "agents": list }));
            last_agents = Some(text);
        }
        if let Some(pane) = only {
            let mut v = match agents.first() {
                Some(a) => crate::screen::Reading::of(a).to_json(a),
                None => json!({ "pane": pane, "kind": null }),
            };
            v["t"] = json!("screen");
            let text = v.to_string();
            if last_screen.as_deref() != Some(text.as_str()) {
                out.send(v);
                last_screen = Some(text);
            }
        }
        std::thread::sleep(tick);
        if gone.load(Ordering::SeqCst) {
            return 0;
        }
        if beat.elapsed() >= crate::follow::HEARTBEAT {
            beat = std::time::Instant::now();
            let mut err = std::io::stderr();
            if err.write_all(b".").and_then(|_| err.flush()).is_err() {
                return 0;
            }
        }
    }
}

// ---------------------------------------------------------------- Claude

/// Claude Code's session files, `~/.claude/sessions/<pid>.json`, one per
/// live Claude process, written and removed by Claude itself: the session
/// it is running, its folder, and `status` (busy, waiting, idle).
///
/// A session can be handed to a background process while its pane stays
/// open (measured on 2.1.311, 2026-11-06: one left-arrow press on an empty
/// prompt). The pane's process stays as a viewer and its file gains
/// `parkedJobId` and is never written again, `busy` for good; the
/// background process's file carries the same id as `jobId`, the new
/// session and the live state.
struct ClaudeSessions {
    by_pid: HashMap<u32, Map<String, Value>>,
    by_job: HashMap<String, u32>,
}

impl ClaudeSessions {
    fn read(host: &dyn Host) -> ClaudeSessions {
        let mut by_pid = HashMap::new();
        let mut by_job = HashMap::new();
        let dir = paths::claude_dir().join("sessions");
        for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(pid) = name
                .strip_suffix(".json")
                .and_then(|p| p.parse::<u32>().ok())
            else {
                continue;
            };
            // A file outlives a process that was killed.
            if !host.alive(pid) {
                continue;
            }
            let Some(Value::Object(map)) = fs::read(entry.path())
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
            else {
                continue;
            };
            if let Some(job) = map.get("jobId").and_then(Value::as_str) {
                by_job.insert(job.to_owned(), pid);
            }
            by_pid.insert(pid, map);
        }
        ClaudeSessions { by_pid, by_job }
    }

    /// The file that speaks for the session shown by `pid`: its own, or the
    /// background process's it handed its session to.
    fn speaking_for(&self, pid: u32) -> Option<&Map<String, Value>> {
        let own = self.by_pid.get(&pid)?;
        let parked = own.get("parkedJobId").and_then(Value::as_str);
        match parked
            .and_then(|job| self.by_job.get(job))
            .and_then(|p| self.by_pid.get(p))
        {
            Some(runner) => Some(runner),
            None => Some(own),
        }
    }
}

struct Claude;

/// Claude Code names its process after its version.
fn is_version(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// `~/.claude/projects/<cwd>/<session>.jsonl`, the folder named after the
/// working directory with every character that is not an ASCII letter or
/// digit turned into `-`.
pub fn claude_transcript(cwd: &str, session: &str) -> PathBuf {
    let folder: String = cwd
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    paths::claude_dir()
        .join("projects")
        .join(folder)
        .join(format!("{session}.jsonl"))
}

impl Provider for Claude {
    fn kind(&self) -> &'static str {
        "claude"
    }

    fn is_process(&self, pid: u32, name: &str, ctx: &Context) -> bool {
        ctx.claude.by_pid.contains_key(&pid) || name == "claude" || is_version(name)
    }

    fn is_command(&self, command: &str) -> bool {
        command == "claude" || is_version(command)
    }

    fn describe(&self, pane: &Pane, pid: Option<u32>, ctx: &mut Context) -> Agent {
        let mut agent = Agent::new(pane, pid, self.kind());
        let Some(file) = pid.and_then(|p| ctx.claude.speaking_for(p)) else {
            return agent;
        };
        let text = |k: &str| file.get(k).and_then(Value::as_str).map(str::to_owned);
        agent.since = file
            .get("statusUpdatedAt")
            .and_then(Value::as_u64)
            .map(|ms| ms / 1000);
        agent.state = match text("status").as_deref() {
            Some("busy") => State::Working,
            Some("waiting") => State::NeedsYou,
            Some("idle") => State::Idle,
            _ => State::Unknown,
        };
        agent.cwd = text("cwd");
        if let (Some(session), Some(cwd)) =
            (text("sessionId").filter(|s| safe_id(s)), agent.cwd.clone())
        {
            let transcript = claude_transcript(&cwd, &session);
            // A session that has never had a turn has nothing to be Done with.
            let has_turns = fs::metadata(&transcript).is_ok_and(|m| m.len() > 0);
            if agent.state == State::Idle && has_turns {
                agent.turn_ended = agent.since;
            }
            agent.transcript = Some(transcript.to_string_lossy().into_owned());
            agent.conversation = Some(session);
        }
        agent
    }
}

// ---------------------------------------------------------------- agy

/// Antigravity (`agy`). It keeps no state file; the conversation a process
/// shows is the `presence/<conversation>.lock` it holds open, the way
/// herdr-web-ui finds it, and what it is doing is read from its screen.
struct Agy;

pub fn agy_transcript(conversation: &str) -> PathBuf {
    paths::home()
        .join(".gemini/antigravity-cli/brain")
        .join(conversation)
        .join(".system_generated/logs/transcript_full.jsonl")
}

impl Agy {
    fn locks<'c>(ctx: &'c mut Context) -> &'c HashMap<u32, Vec<String>> {
        if ctx.agy_locks.is_none() {
            let pids: Vec<u32> = ctx
                .names
                .iter()
                .filter(|(_, n)| matches!(n.as_str(), "agy" | "antigravity"))
                .map(|(p, _)| *p)
                .collect();
            let mut locks: HashMap<u32, Vec<String>> = HashMap::new();
            for (pid, path) in ctx.host.open_files(&pids) {
                let Some(file) = path.rsplit_once("/presence/").map(|(_, f)| f) else {
                    continue;
                };
                if let Some(conversation) = file.strip_suffix(".lock").filter(|c| safe_id(c)) {
                    locks.entry(pid).or_default().push(conversation.to_owned());
                }
            }
            ctx.agy_locks = Some(locks);
        }
        ctx.agy_locks.as_ref().unwrap()
    }
}

/// The model agy is set to, from its own settings.
pub fn agy_model() -> Option<String> {
    let v: Value = serde_json::from_slice(
        &fs::read(paths::home().join(".gemini/antigravity-cli/settings.json")).ok()?,
    )
    .ok()?;
    v.get("model")?.as_str().map(str::to_owned)
}

impl Provider for Agy {
    fn kind(&self) -> &'static str {
        "agy"
    }

    fn reads_screen(&self) -> bool {
        true
    }

    fn is_process(&self, _pid: u32, name: &str, _ctx: &Context) -> bool {
        name == "agy" || name == "antigravity"
    }

    fn is_command(&self, command: &str) -> bool {
        command == "agy" || command == "antigravity"
    }

    fn describe(&self, pane: &Pane, pid: Option<u32>, ctx: &mut Context) -> Agent {
        let mut agent = Agent::new(pane, pid, self.kind());
        agent.state = agy_state(&ctx.screen(&pane.id));
        agent.model = agy_model();
        if let Some(pid) = pid {
            let under = descendants(pid, &ctx.children);
            let locks = Agy::locks(ctx);
            let mut held: Vec<&String> = under
                .iter()
                .filter_map(|p| locks.get(p))
                .flatten()
                .collect();
            held.sort();
            held.dedup();
            // A fresh agy holds none until its first message; two would be a
            // guess.
            if let [conversation] = held[..] {
                let transcript = agy_transcript(conversation);
                if agent.state == State::Idle {
                    // As for Claude: a conversation that has never had a turn
                    // has nothing to be Done with.
                    agent.turn_ended = fs::metadata(&transcript)
                        .ok()
                        .filter(|m| m.len() > 0)
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_secs());
                    // Idle began when the turn ended, as Claude's `since`
                    // says. Without it every agy sorted below every Claude
                    // in the idle group, however recently it was used.
                    // Unlike Claude's transcript, agy's gets no records
                    // while idle: measured 2026-11-09 on 13 idle agy panes,
                    // its mtime was within a minute of the last
                    // `created_at` in it.
                    agent.since = agent.turn_ended;
                }
                agent.transcript = Some(transcript.to_string_lossy().into_owned());
                agent.conversation = Some(conversation.clone());
            }
        }
        agent
    }
}

/// agy's state from its screen, as measured on agy 1.4.12: a menu footer
/// (`navigate` with `tab amend` or `esc skip`), the folder trust question or
/// a permission request means it waits on the person; `esc to cancel` in the
/// footer or a braille spinner starting a line means it is working.
pub fn agy_state(screen: &[String]) -> State {
    let lines: Vec<&str> = screen
        .iter()
        .map(String::as_str)
        .filter(|l| !l.trim().is_empty())
        .collect();
    let tail = &lines[lines.len().saturating_sub(12)..];
    let low: Vec<String> = tail.iter().map(|l| l.to_lowercase()).collect();
    let foot = low[low.len().saturating_sub(4)..].join("\n");
    let all = low.join("\n");
    if foot.contains("navigate") && (foot.contains("tab amend") || foot.contains("esc skip")) {
        return State::NeedsYou;
    }
    if all.contains("do you trust the contents of this project?")
        || all.contains("requesting permission for:")
    {
        return State::NeedsYou;
    }
    if foot.contains("esc to cancel") {
        return State::Working;
    }
    if tail.iter().any(|l| {
        l.trim_start()
            .chars()
            .next()
            .is_some_and(|c| ('\u{2800}'..='\u{28FF}').contains(&c))
    }) {
        return State::Working;
    }
    State::Idle
}

// ---------------------------------------------------------------- others

/// An agent recognised by name only: its pane is listed, its state is not
/// known until someone writes a provider that reads its files.
struct Recognised {
    kind: &'static str,
    names: &'static [&'static str],
}

impl Recognised {
    fn matches(&self, s: &str) -> bool {
        self.names
            .iter()
            .any(|n| s == *n || s.starts_with(&format!("{n}-")))
    }
}

impl Provider for Recognised {
    fn kind(&self) -> &'static str {
        self.kind
    }

    fn is_process(&self, _pid: u32, name: &str, _ctx: &Context) -> bool {
        self.matches(name)
    }

    fn is_command(&self, command: &str) -> bool {
        self.matches(command)
    }

    fn describe(&self, pane: &Pane, pid: Option<u32>, _ctx: &mut Context) -> Agent {
        Agent::new(pane, pid, self.kind)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::Process;
    use std::collections::HashSet;
    use std::time::Duration;

    /// A machine laid out by hand.
    #[derive(Default)]
    struct Fake {
        panes: Vec<Pane>,
        processes: Vec<Process>,
        screens: HashMap<String, Vec<String>>,
        files: Vec<(u32, String)>,
        dead: HashSet<u32>,
    }

    impl Host for Fake {
        fn panes(&self) -> Vec<Pane> {
            self.panes.clone()
        }
        fn processes(&self) -> Vec<Process> {
            self.processes.clone()
        }
        fn screen(&self, pane: &str) -> Vec<String> {
            self.screens.get(pane).cloned().unwrap_or_default()
        }
        fn open_files(&self, pids: &[u32]) -> Vec<(u32, String)> {
            self.files
                .iter()
                .filter(|(p, _)| pids.contains(p))
                .cloned()
                .collect()
        }
        fn alive(&self, pid: u32) -> bool {
            !self.dead.contains(&pid)
        }
    }

    impl Fake {
        fn pane(&mut self, id: &str, pid: u32, command: &str) {
            self.panes.push(Pane {
                id: id.into(),
                pid,
                session_name: "Dev".into(),
                window_id: "@1".into(),
                window_index: "1".into(),
                window_name: "w".into(),
                command: command.into(),
                path: "/w".into(),
                renamed: false,
                title: "t".into(),
            });
        }
        fn process(&mut self, pid: u32, ppid: u32, name: &str) {
            self.processes.push(Process {
                pid,
                ppid,
                name: name.into(),
            });
        }
    }

    /// Runs `f` with a home folder of its own.
    fn with_home<T>(f: impl FnOnce(&std::path::Path) -> T) -> T {
        let dir = tempfile::tempdir().unwrap();
        crate::paths::TEST_HOME.with(|h| *h.borrow_mut() = Some(dir.path().to_path_buf()));
        let out = f(dir.path());
        crate::paths::TEST_HOME.with(|h| *h.borrow_mut() = None);
        out
    }

    fn session_file(home: &std::path::Path, pid: u32, body: Value) {
        let dir = home.join(".claude/sessions");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(format!("{pid}.json")), body.to_string()).unwrap();
    }

    fn transcript(path: &PathBuf, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn seen(kind: &str, conversation: &str, at: u64) {
        let p = seen_path(kind, conversation);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, json!({ "at": at }).to_string()).unwrap();
    }

    #[test]
    fn a_claude_pane_is_found_through_the_process_tree() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%145", 100, "2.1.311");
            m.process(100, 1, "zsh");
            m.process(101, 100, "2.1.311");
            session_file(
                home,
                101,
                json!({ "sessionId": "s1", "cwd": "/Users/j/Code/A b", "status": "busy", "statusUpdatedAt": 5_000 }),
            );
            let a = discover(&m, None).remove(0);
            assert_eq!(
                (a.kind, a.state, a.pid),
                ("claude", State::Working, Some(101))
            );
            assert_eq!(a.conversation.as_deref(), Some("s1"));
            assert_eq!(a.since, Some(5));
            assert_eq!(
                a.transcript.unwrap(),
                home.join(".claude/projects/-Users-j-Code-A-b/s1.jsonl")
                    .to_string_lossy()
            );
        })
    }

    #[test]
    fn a_session_handed_to_a_background_process_is_read_from_it() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%145", 200, "2.1.311");
            m.process(200, 1, "zsh");
            m.process(201, 200, "2.1.311");
            // Not under any pane.
            m.process(300, 1, "claude");
            session_file(
                home,
                201,
                json!({ "sessionId": "old", "cwd": "/w", "status": "busy", "parkedJobId": "j1" }),
            );
            session_file(
                home,
                300,
                json!({ "sessionId": "new", "cwd": "/w", "status": "waiting", "jobId": "j1", "statusUpdatedAt": 9_000 }),
            );
            let agents = discover(&m, None);
            assert_eq!(agents.len(), 1);
            assert_eq!(agents[0].conversation.as_deref(), Some("new"));
            assert_eq!(agents[0].state, State::NeedsYou);
        })
    }

    #[test]
    fn done_lasts_until_the_conversation_is_seen() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%1", 100, "2.1.311");
            m.process(101, 100, "2.1.311");
            session_file(
                home,
                101,
                json!({ "sessionId": "s", "cwd": "/w", "status": "idle", "statusUpdatedAt": 10_000_000 }),
            );
            transcript(&claude_transcript("/w", "s"), "{}\n");
            assert_eq!(discover(&m, None)[0].state, State::Done);
            seen("claude", "s", 10_001);
            assert_eq!(discover(&m, None)[0].state, State::Idle);
            // Another turn, ended after it was seen.
            session_file(
                home,
                101,
                json!({ "sessionId": "s", "cwd": "/w", "status": "idle", "statusUpdatedAt": 20_000_000 }),
            );
            assert_eq!(discover(&m, None)[0].state, State::Done);
        })
    }

    #[test]
    fn a_session_that_never_had_a_turn_is_idle() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%1", 100, "2.1.311");
            session_file(
                home,
                100,
                json!({ "sessionId": "s", "cwd": "/w", "status": "idle", "statusUpdatedAt": 1_000 }),
            );
            assert_eq!(discover(&m, None)[0].state, State::Idle);
        })
    }

    #[test]
    fn a_session_file_left_by_a_killed_process_says_nothing() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%1", 100, "2.1.311");
            m.process(100, 1, "2.1.311");
            m.dead.insert(100);
            session_file(
                home,
                100,
                json!({ "sessionId": "s", "cwd": "/w", "status": "busy" }),
            );
            let a = discover(&m, None).remove(0);
            assert_eq!((a.kind, a.state), ("claude", State::Unknown));
            assert_eq!(a.conversation, None);
        })
    }

    const UUID: &str = "37eabe5b-ec94-4711-9ffb-c87b830d58bb";

    #[test]
    fn an_agy_pane_names_the_conversation_it_holds_and_reads_its_screen() {
        with_home(|_| {
            let mut m = Fake::default();
            m.pane("%110", 400, "agy");
            m.process(400, 1, "zsh");
            m.process(401, 400, "agy");
            m.files.push((
                401,
                format!("/h/.gemini/antigravity-cli/presence/{UUID}.lock"),
            ));
            m.files.push((401, "/h/other.log".into()));
            m.screens.insert(
                "%110".into(),
                vec!["> fix it".into(), "".into(), "  esc to cancel".into()],
            );
            let a = discover(&m, None).remove(0);
            assert_eq!((a.kind, a.state), ("agy", State::Working));
            assert_eq!(a.conversation.as_deref(), Some(UUID));
            assert!(a.transcript.unwrap().ends_with(&format!(
                "brain/{UUID}/.system_generated/logs/transcript_full.jsonl"
            )));
        })
    }

    #[test]
    fn an_idle_agy_is_done_until_seen_by_its_transcript_time() {
        with_home(|_| {
            let mut m = Fake::default();
            m.pane("%110", 401, "agy");
            m.process(401, 1, "agy");
            m.files.push((401, format!("/x/presence/{UUID}.lock")));
            m.screens.insert("%110".into(), vec!["done.".into()]);
            transcript(&agy_transcript(UUID), "{}\n");
            let found = discover(&m, None);
            assert_eq!(found[0].state, State::Done);
            assert!(found[0].since.is_some());
            assert_eq!(found[0].since, found[0].turn_ended);
            seen("agy", UUID, now() + 5);
            assert_eq!(discover(&m, None)[0].state, State::Idle);
        })
    }

    #[test]
    fn agy_holding_two_conversations_names_neither() {
        with_home(|_| {
            let mut m = Fake::default();
            m.pane("%110", 401, "agy");
            m.process(401, 1, "agy");
            m.files.push((401, format!("/x/presence/{UUID}.lock")));
            m.files.push((
                401,
                "/x/presence/9b5fd90d-0000-0000-0000-000000000000.lock".into(),
            ));
            assert_eq!(discover(&m, None)[0].conversation, None);
        })
    }

    #[test]
    fn agy_screens_read_as_measured() {
        let s =
            |lines: &[&str]| agy_state(&lines.iter().map(|l| l.to_string()).collect::<Vec<_>>());
        assert_eq!(
            s(&["Allow this?", "↑↓ navigate · tab amend · enter select"]),
            State::NeedsYou
        );
        assert_eq!(s(&["Pick one", "navigate · esc skip"]), State::NeedsYou);
        assert_eq!(
            s(&["Do you trust the contents of this project?", "", "1. Yes"]),
            State::NeedsYou
        );
        assert_eq!(
            s(&["Requesting permission for:", "rm -rf build"]),
            State::NeedsYou
        );
        assert_eq!(s(&["thinking", "esc to cancel"]), State::Working);
        assert_eq!(s(&["\u{280b} Generating"]), State::Working);
        assert_eq!(s(&["All done.", "> "]), State::Idle);
        // A navigate footer long gone above the last few lines does not count.
        assert_eq!(
            s(&["navigate · tab amend", "a", "b", "c", "d"]),
            State::Idle
        );
    }

    #[test]
    fn the_nearest_agent_owns_the_pane() {
        with_home(|home| {
            let mut m = Fake::default();
            m.pane("%5", 500, "2.1.311");
            m.process(500, 1, "zsh");
            m.process(501, 500, "2.1.311");
            m.process(502, 501, "agy");
            session_file(
                home,
                501,
                json!({ "sessionId": "s", "cwd": "/w", "status": "busy" }),
            );
            assert_eq!(discover(&m, None)[0].kind, "claude");
        })
    }

    #[test]
    fn other_agents_are_listed_with_no_state_and_shells_are_not() {
        with_home(|_| {
            let mut m = Fake::default();
            m.pane("%17", 600, "grok-1.0.52-mac");
            m.process(600, 1, "zsh");
            m.pane("%18", 700, "zsh");
            m.process(700, 1, "zsh");
            let agents = discover(&m, None);
            assert_eq!(agents.len(), 1);
            assert_eq!((agents[0].kind, agents[0].state), ("grok", State::Unknown));
        })
    }

    #[test]
    fn asking_about_one_pane_reads_only_that_one() {
        with_home(|_| {
            let mut m = Fake::default();
            m.pane("%1", 1001, "agy");
            m.process(1001, 1, "agy");
            m.pane("%2", 1002, "agy");
            m.process(1002, 1, "agy");
            let agents = discover(&m, Some("%2"));
            assert_eq!(
                agents
                    .iter()
                    .map(|a| a.pane.id.as_str())
                    .collect::<Vec<_>>(),
                vec!["%2"]
            );
        })
    }

    #[test]
    fn many_screens_are_read_at_once() {
        struct Slow(Fake);
        impl Host for Slow {
            fn panes(&self) -> Vec<Pane> {
                self.0.panes()
            }
            fn processes(&self) -> Vec<Process> {
                self.0.processes()
            }
            fn screen(&self, _: &str) -> Vec<String> {
                std::thread::sleep(Duration::from_millis(100));
                vec!["esc to cancel".into()]
            }
            fn open_files(&self, _: &[u32]) -> Vec<(u32, String)> {
                Vec::new()
            }
            fn alive(&self, _: u32) -> bool {
                true
            }
        }
        with_home(|_| {
            let mut m = Fake::default();
            for i in 0..8u32 {
                m.pane(&format!("%{i}"), 2000 + i, "agy");
                m.process(2000 + i, 1, "agy");
            }
            let started = std::time::Instant::now();
            let agents = discover(&Slow(m), None);
            assert!(agents.iter().all(|a| a.state == State::Working));
            assert!(
                started.elapsed() < Duration::from_millis(500),
                "{:?}",
                started.elapsed()
            );
        })
    }

    #[test]
    fn seen_keeps_the_later_time() {
        with_home(|_| {
            seen("claude", "s", now() + 1000);
            assert_eq!(run_seen(&["claude".into(), "s".into()]), 0);
            // Marking it seen now did not move it back.
            assert!(seen_at("claude", "s").unwrap() >= now() + 999);
            assert_eq!(run_seen(&["claude".into(), "../x".into()]), 2);
        })
    }

    #[test]
    fn a_name_is_one_tidy_line_that_tmux_takes_literally() {
        // "\t你好\t world\n": control characters and runs of space go.
        assert_eq!(tidy_name("\t你好\t world\n"), "你好 world");
        assert_eq!(tidy_name("   "), "");
        assert_eq!(tidy_name(&"x".repeat(500)).chars().count(), NAME_MAX);
        // Every # doubled: no format, no #(command), survives.
        assert_eq!(tmux_literal("a #{pane_id} #(touch x) ##"), "a ##{pane_id} ##(touch x) ####");
        // Refused before tmux is asked anything.
        assert_eq!(run_rename(&["%1".into(), "--name".into(), "a b".into()]), 2);
        assert_eq!(run_rename(&["1".into(), "--name".into(), "YQ==".into()]), 2);
        assert_eq!(run_rename(&["%1".into(), "--title".into(), "YQ==".into()]), 2);
    }
}
