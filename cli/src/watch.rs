//! `agents --watch [--pane %N]` on macOS: the same output as the polling
//! loop in `agents`, but the work is done when the kernel says something
//! changed, not on a timer.
//!
//! Why: the polling loop ran `ps`, `tmux list-panes` and `tmux
//! capture-pane` every 0.5 s per watched pane whether or not anything had
//! changed. Every process started on macOS advances the kernel's boot-wide
//! 32-bit pidversion counter (fork and exec both); on 2026-11-20 it passed
//! 2^31 after 46 days up, and from that second launchd refused every new
//! process its service lookups until a reboot.
//!
//! What each change is known by (all measured on macOS 27 / tmux 3.6a,
//! 2026-11-23, against an isolated `-L` server):
//!
//! ```text
//! a program writes to a pane's screen   NOTE_WRITE on the pane's tty (/dev/ttysNNN);
//!                                       nothing at all while the pane is quiet
//! a pane, window or session is opened   NOTE_WRITE on /dev, once per new tty
//! a program starts, changes or ends     NOTE_FORK / NOTE_EXEC / NOTE_EXIT on the
//!   in a pane                           pane's process and its children
//! Claude's state changes                its file in ~/.claude/sessions
//! agy opens a conversation              agy's presence folder
//! a conversation is marked seen         `seen` touches the state folder
//! ```
//!
//! Holding a pane's tty open (O_EVTONLY) does not keep the pane alive: a
//! shell that exits closes its pane as before (measured).
//!
//! What this deliberately does not do is attach a tmux control client to
//! each session, which would also have carried output and renames as
//! notifications: tmux answers a program's background-colour query (OSC 11)
//! from the first client in its list, and a control client answers black
//! (measured: no client, no answer; a control client alone,
//! `rgb:0000/0000/0000`), so a long-lived one would tell Claude's `auto`
//! theme "dark" in every session the app is not showing.
//!
//! tmux is still asked, by starting `tmux`, for two things only it knows:
//! the pane list (after a pane opened or closed, a program changed, or at
//! most every 3 s while an agent's pane is writing, for its title) and a
//! pane's screen (after the pane wrote, at most every 0.4 s while it keeps
//! writing, and once more after it stops). Nothing else is ever started.
//! A quiet machine starts one `tmux list-panes` a minute, the safety net
//! for what no notification covers: a window renamed by hand.

use crate::agents::{discover, Agent, State};
use crate::follow::{Out, HEARTBEAT};
use crate::host::{darwin, Host, Pane, Process, RealHost};
use crate::paths;
use crate::screen::{self, Reading};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How often everything is asked again although nothing said it changed.
const SAFETY_NET: Duration = Duration::from_secs(60);
/// The watched pane's screen, at most this often while it keeps writing.
const SCREEN_GAP: Duration = Duration::from_millis(400);
/// An agy pane's screen in the list, where it only gives agy's state:
/// this often while agy works or waits on the person.
const AGY_SCREEN_GAP: Duration = Duration::from_secs(1);
/// And this often while it is idle. An idle agy still writes to its tty
/// every two seconds or so with nothing on its screen changing (measured
/// 2026-11-23 on five idle agy 1.4 panes: one write each per ~2 s, two
/// captures six seconds apart identical); read every time, that was most
/// of what a list watch started. A turn beginning is heard sooner, by its
/// transcript being written.
const AGY_IDLE_SCREEN_GAP: Duration = Duration::from_secs(10);
/// The pane list for a title an agent rewrote while it works.
const TITLE_GAP: Duration = Duration::from_secs(3);
/// Programs starting and ending come in bursts (a prompt forks several).
const PROCESS_GAP: Duration = Duration::from_secs(1);
/// How long after a program starts tmux has renamed its window.
const RENAME_LAG: Duration = Duration::from_millis(700);

/// The polling loop is kept for every other system, and for anyone who
/// sets `ATTACHE_WATCH=poll`. `None` means this could not start.
pub fn run(only: Option<&str>) -> Option<i32> {
    if std::env::var("ATTACHE_WATCH").is_ok_and(|v| v == "poll") {
        return None;
    }
    let kq = Kqueue::new()?;
    kq.wake_when_stdin_ends();
    Some(Watch::new(kq, only).run())
}

// ------------------------------------------------------------------ kqueue

const WAKE: usize = 1;
const VNODE_CHANGES: u32 = libc::NOTE_WRITE
    | libc::NOTE_EXTEND
    | libc::NOTE_ATTRIB
    | libc::NOTE_DELETE
    | libc::NOTE_RENAME
    | libc::NOTE_REVOKE;
const TTY_CHANGES: u32 = libc::NOTE_WRITE | libc::NOTE_DELETE | libc::NOTE_REVOKE;
const PANE_PROCESS: u32 = libc::NOTE_FORK | libc::NOTE_EXEC | libc::NOTE_EXIT;
const OTHER_PROCESS: u32 = libc::NOTE_EXEC | libc::NOTE_EXIT;

struct Kqueue {
    fd: RawFd,
}

fn kev(ident: usize, filter: i16, flags: u16, fflags: u32, udata: usize) -> libc::kevent {
    libc::kevent {
        ident,
        filter,
        flags,
        fflags,
        data: 0,
        udata: udata as *mut libc::c_void,
    }
}

impl Kqueue {
    fn new() -> Option<Kqueue> {
        // SAFETY: no arguments; a negative result is an error.
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return None;
        }
        let kq = Kqueue { fd };
        kq.change(kev(WAKE, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, 0))
            .then_some(kq)
    }

    fn change(&self, ev: libc::kevent) -> bool {
        // SAFETY: one change in, no events out.
        unsafe { libc::kevent(self.fd, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) == 0 }
    }

    /// The SSH channel or the app closing ends stdin; nothing is read from
    /// it. Wakes the loop, which then ends.
    fn wake_when_stdin_ends(&self) {
        let fd = self.fd;
        std::thread::spawn(move || {
            use std::io::Read;
            let mut buf = [0u8; 256];
            let mut stdin = std::io::stdin();
            while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
            let ev = kev(WAKE, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, 0);
            // SAFETY: as in `change`; kevent may be called from any thread.
            unsafe { libc::kevent(fd, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
        });
    }

    fn wait(&self, timeout: Duration) -> Vec<libc::kevent> {
        let ts = libc::timespec {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_nsec: timeout.subsec_nanos() as libc::c_long,
        };
        let mut events = vec![kev(0, 0, 0, 0, 0); 64];
        // SAFETY: room for 64 events.
        let n = unsafe {
            libc::kevent(self.fd, std::ptr::null(), 0, events.as_mut_ptr(), 64, &ts)
        };
        events.truncate(n.max(0) as usize);
        events
    }
}

/// What a watched file stands for.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Source {
    /// `/dev`: a tty was made, so a pane was.
    Dev,
    /// Claude's session folder or one file in it.
    Claude,
    /// agy's presence folder.
    Agy,
    /// The state folder `seen` touches.
    Seen,
    /// A pane's tty.
    Tty(String),
    /// The transcript of the agy in this pane: written when a turn begins.
    AgyTranscript(String),
}

/// Files and processes being watched, kept to what the last look found.
struct Watches {
    files: HashMap<PathBuf, (RawFd, Source)>,
    by_fd: HashMap<RawFd, Source>,
    processes: HashMap<u32, u32>,
}

impl Watches {
    fn watch_file(&mut self, kq: &Kqueue, path: &Path, source: Source, fflags: u32) {
        if self.files.contains_key(path) {
            return;
        }
        let Ok(c) = CString::new(path.as_os_str().as_bytes()) else { return };
        // O_EVTONLY: for notifications only; O_NOCTTY: a tty opened here
        // must never become this process's controlling terminal.
        // SAFETY: a NUL-terminated path.
        let fd = unsafe {
            libc::open(
                c.as_ptr(),
                libc::O_EVTONLY | libc::O_NOCTTY | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return;
        }
        let ev = kev(
            fd as usize,
            libc::EVFILT_VNODE,
            libc::EV_ADD | libc::EV_CLEAR,
            fflags,
            0,
        );
        if !kq.change(ev) {
            // SAFETY: ours, opened above.
            unsafe { libc::close(fd) };
            return;
        }
        self.by_fd.insert(fd, source.clone());
        self.files.insert(path.to_owned(), (fd, source));
    }

    /// Closing the file drops its notification with it.
    fn forget_file(&mut self, path: &Path) {
        if let Some((fd, _)) = self.files.remove(path) {
            self.by_fd.remove(&fd);
            // SAFETY: ours, opened in `watch_file`.
            unsafe { libc::close(fd) };
        }
    }

    fn watch_process(&mut self, kq: &Kqueue, pid: u32, fflags: u32) {
        if self.processes.get(&pid) == Some(&fflags) {
            return;
        }
        let ev = kev(pid as usize, libc::EVFILT_PROC, libc::EV_ADD | libc::EV_CLEAR, fflags, 0);
        if kq.change(ev) {
            self.processes.insert(pid, fflags);
        }
    }

    fn forget_process(&mut self, kq: &Kqueue, pid: u32) {
        if self.processes.remove(&pid).is_some() {
            kq.change(kev(pid as usize, libc::EVFILT_PROC, libc::EV_DELETE, 0, 0));
        }
    }
}

// --------------------------------------------------------------- the host

/// The real host, with what it read kept until a notification says it
/// changed. The pane list and screens are the only things asked of tmux,
/// by starting it; the process table and agy's open files cost no process
/// but a call per process and per open file (about a thousand and several
/// hundred here), which a pane rewriting its title has no bearing on.
struct Cached {
    real: RealHost,
    panes: Mutex<Option<Vec<Pane>>>,
    screens: Mutex<HashMap<String, Vec<String>>>,
    processes: Mutex<Option<Vec<Process>>>,
    files: Mutex<HashMap<Vec<u32>, Vec<(u32, String)>>>,
}

impl Cached {
    /// The pane list as last read, without reading it.
    fn panes_known(&self) -> Option<Vec<Pane>> {
        self.panes.lock().unwrap().clone()
    }

    fn forget_panes(&self) {
        *self.panes.lock().unwrap() = None;
    }

    fn forget_processes(&self) {
        *self.processes.lock().unwrap() = None;
        self.files.lock().unwrap().clear();
    }

    fn forget_screen(&self, pane: &str) {
        self.screens.lock().unwrap().remove(pane);
    }
}

impl Host for Cached {
    fn panes(&self) -> Vec<Pane> {
        if let Some(p) = self.panes.lock().unwrap().as_ref() {
            return p.clone();
        }
        let fresh = self.real.panes();
        *self.panes.lock().unwrap() = Some(fresh.clone());
        fresh
    }

    fn processes(&self) -> Vec<Process> {
        if let Some(p) = self.processes.lock().unwrap().as_ref() {
            return p.clone();
        }
        let fresh = self.real.processes();
        *self.processes.lock().unwrap() = Some(fresh.clone());
        fresh
    }

    fn screen(&self, pane: &str) -> Vec<String> {
        if let Some(s) = self.screens.lock().unwrap().get(pane) {
            return s.clone();
        }
        // Not under the lock: `discover` reads many screens at once.
        let fresh = self.real.screen(pane);
        self.screens
            .lock()
            .unwrap()
            .insert(pane.to_owned(), fresh.clone());
        fresh
    }

    fn open_files(&self, pids: &[u32]) -> Vec<(u32, String)> {
        if let Some(f) = self.files.lock().unwrap().get(pids) {
            return f.clone();
        }
        let fresh = self.real.open_files(pids);
        self.files.lock().unwrap().insert(pids.to_vec(), fresh.clone());
        fresh
    }

    fn alive(&self, pid: u32) -> bool {
        self.real.alive(pid)
    }
}

// --------------------------------------------------------------- schedule

/// One kind of work to do: when it is due, and when it was last done so a
/// pane that keeps writing is read at most once per gap. The first change
/// after a quiet spell is acted on at once (after `debounce`, which gathers
/// a burst), and the last change of a busy spell is always acted on, so
/// what was sent is never older than the screen.
#[derive(Default)]
struct Due {
    at: Option<Instant>,
    last: Option<Instant>,
}

impl Due {
    fn ask(&mut self, now: Instant, debounce: Duration, gap: Duration) {
        let mut at = now + debounce;
        if let Some(last) = self.last {
            at = at.max(last + gap);
        }
        self.at = Some(self.at.map_or(at, |a| a.min(at)));
    }

    fn take(&mut self, now: Instant) -> bool {
        if self.at.is_some_and(|a| a <= now) {
            self.at = None;
            self.last = Some(now);
            return true;
        }
        false
    }
}

// ------------------------------------------------------------------ watch

struct Watch<'a> {
    kq: Kqueue,
    only: Option<&'a str>,
    host: Cached,
    watches: Watches,
    out: Out,
    last_agents: Option<String>,
    last_screen: Option<String>,
    /// The watched pane's screen with history, for Claude's readers.
    capture: Option<Vec<String>>,
    agents_due: Due,
    panes_due: Due,
    /// The pane list once more after a program started or a pane opened:
    /// tmux renames a window after its program (`automatic-rename`) on a
    /// timer of its own, about half a second later, and nothing is heard
    /// when it does (measured: `zsh` read 30 ms after a respawn, `claude`
    /// some 0.5 s after).
    rename_due: Due,
    screen_due: Due,
    agy_due: HashMap<String, Due>,
    /// Something that bears on the process table or agy's open files was
    /// heard since they were last read.
    processes_stale: bool,
    /// The panes the last look found an agent in, and of which kind.
    agent_panes: HashMap<String, (&'static str, State)>,
}

impl<'a> Watch<'a> {
    fn new(kq: Kqueue, only: Option<&'a str>) -> Watch<'a> {
        let mut w = Watch {
            kq,
            only,
            host: Cached {
                real: RealHost,
                panes: Mutex::new(None),
                processes: Mutex::new(None),
                files: Mutex::new(HashMap::new()),
                screens: Mutex::new(HashMap::new()),
            },
            watches: Watches {
                files: HashMap::new(),
                by_fd: HashMap::new(),
                processes: HashMap::new(),
            },
            out: Out::default(),
            last_agents: None,
            last_screen: None,
            capture: None,
            agents_due: Due::default(),
            rename_due: Due::default(),
            panes_due: Due::default(),
            screen_due: Due::default(),
            agy_due: HashMap::new(),
            agent_panes: HashMap::new(),
            processes_stale: true,
        };
        let state = paths::state_dir();
        let _ = std::fs::create_dir_all(&state);
        let folders = [
            (PathBuf::from("/dev"), Source::Dev),
            (paths::claude_dir().join("sessions"), Source::Claude),
            (paths::home().join(".gemini/antigravity-cli/presence"), Source::Agy),
            (state, Source::Seen),
        ];
        for (path, source) in folders {
            w.watches.watch_file(&w.kq, &path, source, VNODE_CHANGES);
        }
        w
    }

    fn run(&mut self) -> i32 {
        let mut beat = Instant::now() + HEARTBEAT;
        let mut safety = Instant::now() + SAFETY_NET;
        self.look(true);
        loop {
            let now = Instant::now();
            let next = [
                self.agents_due.at,
                self.rename_due.at,
                self.panes_due.at,
                self.screen_due.at,
                self.agy_due.values().filter_map(|d| d.at).min(),
                Some(beat),
                Some(safety),
            ]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(beat);
            for ev in self.kq.wait(next.saturating_duration_since(now)) {
                if ev.filter == libc::EVFILT_USER {
                    return 0;
                }
                self.heard(&ev);
            }
            let now = Instant::now();
            if now >= beat {
                beat = now + HEARTBEAT;
                let mut err = std::io::stderr();
                if err.write_all(b".").and_then(|_| err.flush()).is_err() {
                    return 0;
                }
            }
            if now >= safety {
                safety = now + SAFETY_NET;
                self.panes_due.ask(now, Duration::ZERO, Duration::ZERO);
                self.processes_stale = true;
            }
            self.look(false);
        }
    }

    /// Sorts one notification into the work it calls for.
    fn heard(&mut self, ev: &libc::kevent) {
        let now = Instant::now();
        let soon = Duration::from_millis(30);
        if ev.filter == libc::EVFILT_PROC {
            self.processes_stale = true;
            if ev.fflags & libc::NOTE_EXIT != 0 {
                // An exit removes the notification with the process.
                self.watches.processes.remove(&(ev.ident as u32));
            }
            if ev.fflags & (libc::NOTE_EXIT | libc::NOTE_EXEC) != 0 {
                // A program that changed or ended is acted on at once: a
                // pane respawned has another process, a closed one none.
                self.panes_due.ask(now, Duration::from_millis(100), Duration::ZERO);
                self.rename_due.ask(now, RENAME_LAG, Duration::ZERO);
            } else {
                // A fork alone comes in bursts (a shell prompt starts
                // several), and what it starts is heard of by its exec.
                self.panes_due.ask(now, Duration::from_millis(150), PROCESS_GAP);
            }
            return;
        }
        let Some(source) = self.watches.by_fd.get(&(ev.ident as RawFd)).cloned() else {
            return;
        };
        if ev.fflags & (libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE) != 0 {
            // The file was replaced or the tty went with its pane: watched
            // again, by its path, on the next look.
            let path = self
                .watches
                .files
                .iter()
                .find(|(_, (fd, _))| *fd == ev.ident as RawFd)
                .map(|(p, _)| p.clone());
            if let Some(path) = path {
                self.watches.forget_file(&path);
            }
        }
        if !matches!(source, Source::Tty(_) | Source::Seen) {
            self.processes_stale = true;
        }
        match source {
            Source::Dev => {
                self.panes_due.ask(now, Duration::from_millis(100), Duration::ZERO);
                self.rename_due.ask(now, RENAME_LAG, Duration::ZERO);
            }
            Source::AgyTranscript(pane) => {
                if self.only == Some(pane.as_str()) {
                    self.screen_due.ask(now, soon, SCREEN_GAP);
                } else {
                    self.agy_due.entry(pane).or_default().ask(now, soon, Duration::ZERO);
                }
                self.agents_due.ask(now, soon, Duration::ZERO);
            }
            Source::Claude | Source::Agy | Source::Seen => {
                self.agents_due.ask(now, soon, Duration::ZERO);
                if self.only.is_some() {
                    self.screen_due.ask(now, soon, SCREEN_GAP);
                }
            }
            Source::Tty(pane) => {
                if self.only == Some(pane.as_str()) {
                    self.screen_due.ask(now, soon, SCREEN_GAP);
                } else if let Some(&("agy", state)) = self.agent_panes.get(&pane) {
                    let gap = match state {
                        State::Working | State::NeedsYou => AGY_SCREEN_GAP,
                        _ => AGY_IDLE_SCREEN_GAP,
                    };
                    self.agy_due
                        .entry(pane)
                        .or_default()
                        .ask(now, Duration::from_millis(100), gap);
                }
                self.panes_due.ask(now, Duration::from_millis(300), TITLE_GAP);
            }
        }
    }

    /// Does whatever is due, sends what changed, and watches what the look
    /// found.
    fn look(&mut self, first: bool) {
        let now = Instant::now();
        let mut any = first;
        if self.panes_due.take(now) {
            self.host.forget_panes();
            any = true;
        }
        if self.screen_due.take(now) {
            self.capture = None;
            if let Some(pane) = self.only {
                self.host.forget_screen(pane);
            }
            any = true;
        }
        for (pane, due) in self.agy_due.iter_mut() {
            if due.take(now) {
                self.host.forget_screen(pane);
                any = true;
            }
        }
        if self.agents_due.take(now) {
            any = true;
        }
        if self.rename_due.take(now) {
            self.host.forget_panes();
            any = true;
        }
        if !any {
            return;
        }
        // A pane list asked for moments ago is read with this look, not
        // just after it: a pane respawned is heard of by its tty (the new
        // program drawing) before its old process's exit is acted on, and
        // the screen would go out ahead of the agent it belongs to.
        // Its exit may not even have been heard yet, so a pane whose
        // process is gone is a pane list out of date, whatever is due.
        let stale = self.panes_due.at.is_some_and(|a| a <= now + Duration::from_millis(150))
            || self.host.panes_known().is_some_and(|panes| {
                panes
                    .iter()
                    .filter(|p| self.only.is_none_or(|o| o == p.id))
                    .any(|p| !darwin::running(p.pid))
            });
        if stale {
            self.panes_due.at = None;
            self.panes_due.last = Some(now);
            self.host.forget_panes();
            self.processes_stale = true;
        }
        if std::mem::take(&mut self.processes_stale) {
            self.host.forget_processes();
        }
        let agents = discover(&self.host, self.only);
        let list = Value::Array(agents.iter().map(Agent::to_json).collect());
        let text = list.to_string();
        if self.last_agents.as_deref() != Some(text.as_str()) {
            self.out.send(json!({ "t": "agents", "agents": list }));
            self.last_agents = Some(text);
        }
        if let Some(pane) = self.only {
            let mut v = match agents.first() {
                Some(a) if a.kind == "claude" => {
                    let rows = self.capture.get_or_insert_with(|| screen::capture(pane));
                    Reading::from_lines(rows).to_json(a)
                }
                Some(a) => Reading::nothing().to_json(a),
                None => json!({ "pane": pane, "kind": null }),
            };
            v["t"] = json!("screen");
            let text = v.to_string();
            if self.last_screen.as_deref() != Some(text.as_str()) {
                self.out.send(v);
                self.last_screen = Some(text);
            }
        }
        self.agent_panes = agents
            .iter()
            .map(|a| (a.pane.id.clone(), (a.kind, a.state)))
            .collect();
        self.agy_due.retain(|p, _| self.agent_panes.contains_key(p));
        self.rearm(&agents);
    }

    /// Watches what the look just found and stops watching what it no
    /// longer did.
    fn rearm(&mut self, agents: &[Agent]) {
        let panes = self.host.panes();
        let in_scope: Vec<&Pane> = panes
            .iter()
            .filter(|p| self.only.is_none_or(|o| o == p.id))
            .collect();

        // Ttys: the watched pane's, or every agent's for the list. A pane
        // with no agent is known to start one by its processes.
        let mut ttys: HashMap<PathBuf, String> = HashMap::new();
        for pane in &in_scope {
            let wanted = self.only.is_some() || self.agent_panes.contains_key(&pane.id);
            if wanted && pane.tty.starts_with("/dev/") {
                ttys.insert(PathBuf::from(&pane.tty), pane.id.clone());
            }
        }

        let transcripts: HashMap<PathBuf, String> = agents
            .iter()
            .filter(|a| a.kind == "agy" && self.only.is_none_or(|o| o == a.pane.id))
            .filter_map(|a| Some((PathBuf::from(a.transcript.as_ref()?), a.pane.id.clone())))
            .collect();

        // Processes: tmux's server (its exit ends every pane), each pane's
        // own process for anything it starts, the processes it started for
        // a program changing or ending, and each agent for its end. Not
        // what an agent itself starts: Claude starts one for every tool
        // call, and none of them changes what is shown.
        let agent_pid: HashMap<&str, u32> = agents
            .iter()
            .filter_map(|a| Some((a.pane.id.as_str(), a.pid?)))
            .collect();
        let mut procs: HashMap<u32, u32> = HashMap::new();
        for pane in &in_scope {
            procs.insert(pane.pid, PANE_PROCESS);
            if let Some(server) = darwin::parent(pane.pid).filter(|&p| p > 1) {
                procs.entry(server).or_insert(OTHER_PROCESS);
            }
            for kid in darwin::children(pane.pid) {
                procs.entry(kid).or_insert(OTHER_PROCESS);
            }
            if let Some(&agent) = agent_pid.get(pane.id.as_str()) {
                procs.entry(agent).or_insert(OTHER_PROCESS);
            }
        }

        let kq = &self.kq;
        let w = &mut self.watches;
        let stale: Vec<PathBuf> = w
            .files
            .iter()
            .filter(|(path, (_, s))| match s {
                Source::Tty(_) => !ttys.contains_key(*path),
                Source::AgyTranscript(_) => !transcripts.contains_key(*path),
                Source::Claude => path.extension().is_some() && !path.exists(),
                _ => false,
            })
            .map(|(p, _)| p.clone())
            .collect();
        for path in stale {
            w.forget_file(&path);
        }
        for (path, pane) in ttys {
            w.watch_file(kq, &path, Source::Tty(pane), TTY_CHANGES);
        }
        for (path, pane) in transcripts {
            w.watch_file(kq, &path, Source::AgyTranscript(pane), VNODE_CHANGES);
        }
        // The folders themselves, again if one was replaced or made late.
        let sessions = paths::claude_dir().join("sessions");
        w.watch_file(kq, &sessions, Source::Claude, VNODE_CHANGES);
        w.watch_file(kq, Path::new("/dev"), Source::Dev, VNODE_CHANGES);
        w.watch_file(
            kq,
            &paths::home().join(".gemini/antigravity-cli/presence"),
            Source::Agy,
            VNODE_CHANGES,
        );
        w.watch_file(kq, &paths::state_dir(), Source::Seen, VNODE_CHANGES);
        // Claude rewrites its own file; a folder hears of files coming and
        // going, not of one being written in place.
        for entry in std::fs::read_dir(&sessions).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "json") {
                w.watch_file(kq, &path, Source::Claude, VNODE_CHANGES);
            }
        }

        let gone: Vec<u32> = w
            .processes
            .keys()
            .filter(|p| !procs.contains_key(p))
            .copied()
            .collect();
        for pid in gone {
            w.forget_process(kq, pid);
        }
        let mut seen = HashSet::new();
        for (pid, fflags) in procs {
            if seen.insert(pid) {
                w.watch_process(kq, pid, fflags);
            }
        }
    }
}
