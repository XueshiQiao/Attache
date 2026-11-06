//! What this program asks of the machine: tmux's panes and screens, the
//! process table, and which files a process holds open. Behind a trait so
//! the discovery rules can be tested against any arrangement of panes and
//! processes; files under the home folder are read directly, and tests point
//! `HOME` at a folder of their own.

use crate::tmux;
use std::collections::HashMap;
use std::process::{Command, Stdio};

#[derive(Clone, Debug, Default)]
pub struct Pane {
    /// `%42`.
    pub id: String,
    /// The process tmux started in the pane; every agent in it descends from it.
    pub pid: u32,
    pub session_name: String,
    /// `@7`.
    pub window_id: String,
    pub window_index: String,
    pub window_name: String,
    /// What tmux reads as the pane's foreground command. Claude Code names
    /// its process after its version (`2.1.311`).
    pub command: String,
    pub path: String,
    pub title: String,
}

#[derive(Clone, Debug)]
pub struct Process {
    pub pid: u32,
    pub ppid: u32,
    /// The kernel's short name for it (`agy`, `zsh`).
    pub name: String,
}

pub trait Host: Sync {
    fn panes(&self) -> Vec<Pane>;
    fn processes(&self) -> Vec<Process>;
    /// The pane's visible screen, wrapped lines joined.
    fn screen(&self, pane: &str) -> Vec<String>;
    /// `(pid, path)` for every file the given processes hold open.
    fn open_files(&self, pids: &[u32]) -> Vec<(u32, String)>;
    fn alive(&self, pid: u32) -> bool;
}

/// A tab, not `\x01`: tmux 3.4 (Alpine's) writes a `\x01` in a format as the
/// four characters `\001` whatever the locale, while a tab comes through
/// under `-u` on 3.4 and 3.6a alike (measured 2026-11-06). The title, the one
/// field free text is likely in, goes last, so a tab inside it stays in it.
const SEP: char = '\t';

pub struct RealHost;

impl Host for RealHost {
    fn panes(&self) -> Vec<Pane> {
        let format = [
            "#{pane_id}",
            "#{pane_pid}",
            "#{session_name}",
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{pane_current_command}",
            "#{pane_current_path}",
            "#{pane_title}",
        ]
        .join(&SEP.to_string());
        tmux::lines(&["list-panes", "-a", "-F", &format])
            .iter()
            .filter_map(|line| {
                let f: Vec<&str> = line.splitn(9, SEP).collect();
                if f.len() != 9 || !f[0].starts_with('%') {
                    return None;
                }
                Some(Pane {
                    id: f[0].into(),
                    pid: f[1].parse().ok()?,
                    session_name: f[2].into(),
                    window_id: f[3].into(),
                    window_index: f[4].into(),
                    window_name: f[5].into(),
                    command: f[6].into(),
                    path: f[7].into(),
                    title: f[8].into(),
                })
            })
            .collect()
    }

    fn processes(&self) -> Vec<Process> {
        // Linux says it in /proc, with no `ps` to vary: busybox's (Alpine)
        // takes none of the options below.
        if std::path::Path::new("/proc/self/stat").exists() {
            return proc_processes();
        }
        // macOS: `ucomm` is the short name; `comm` is a full path.
        let out = Command::new("ps")
            .args(["-A", "-o", "pid=", "-o", "ppid=", "-o", "ucomm="])
            .stderr(Stdio::null())
            .output();
        let Ok(out) = out else { return Vec::new() };
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| {
                let mut it = l.split_whitespace();
                let pid = it.next()?.parse().ok()?;
                let ppid = it.next()?.parse().ok()?;
                let name = it.collect::<Vec<_>>().join(" ");
                Some(Process { pid, ppid, name })
            })
            .collect()
    }

    fn screen(&self, pane: &str) -> Vec<String> {
        tmux::lines(&["capture-pane", "-p", "-J", "-t", pane])
    }

    fn open_files(&self, pids: &[u32]) -> Vec<(u32, String)> {
        if pids.is_empty() {
            return Vec::new();
        }
        // Linux says it in /proc without running anything.
        if std::path::Path::new("/proc/self/fd").exists() {
            return pids
                .iter()
                .flat_map(|&pid| {
                    std::fs::read_dir(format!("/proc/{pid}/fd"))
                        .into_iter()
                        .flatten()
                        .flatten()
                        .filter_map(move |e| {
                            std::fs::read_link(e.path())
                                .ok()
                                .map(|p| (pid, p.to_string_lossy().into_owned()))
                        })
                })
                .collect();
        }
        // macOS: lsof on just these processes (20 ms for twelve agy here,
        // where `lsof +d <folder>` walks every process and took 260).
        let list = pids
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let out = Command::new("lsof")
            .args(["-nPw", "-a", "-p", &list, "-Fpn"])
            .stderr(Stdio::null())
            .output();
        let Ok(out) = out else { return Vec::new() };
        let mut files = Vec::new();
        let mut pid = 0;
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            if let Some(p) = line.strip_prefix('p') {
                pid = p.parse().unwrap_or(0);
            } else if let Some(n) = line.strip_prefix('n') {
                files.push((pid, n.to_owned()));
            }
        }
        files
    }

    fn alive(&self, pid: u32) -> bool {
        // SAFETY: signal 0 only checks that the process exists.
        let r = unsafe { libc::kill(pid as libc::pid_t, 0) };
        r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}

/// Every process from `/proc/<pid>/stat`: `pid (name) state ppid …`. The
/// name is in brackets and may itself hold spaces or brackets, so it runs to
/// the last `)`.
fn proc_processes() -> Vec<Process> {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let pid: u32 = e.file_name().to_str()?.parse().ok()?;
            parse_stat(pid, &std::fs::read_to_string(e.path().join("stat")).ok()?)
        })
        .collect()
}

pub fn parse_stat(pid: u32, stat: &str) -> Option<Process> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat.get(open + 1..close)?.to_owned();
    let mut rest = stat.get(close + 1..)?.split_whitespace();
    let _state = rest.next()?;
    let ppid = rest.next()?.parse().ok()?;
    Some(Process { pid, ppid, name })
}

/// Children of each process, for walking down from a pane's process.
pub fn children(processes: &[Process]) -> HashMap<u32, Vec<u32>> {
    let mut map: HashMap<u32, Vec<u32>> = HashMap::new();
    for p in processes {
        map.entry(p.ppid).or_default().push(p.pid);
    }
    map
}

/// The pane's process and everything under it, nearest first.
pub fn descendants(root: u32, children: &HashMap<u32, Vec<u32>>) -> Vec<u32> {
    let mut out = vec![root];
    let mut i = 0;
    while i < out.len() {
        let parent = out[i];
        if let Some(kids) = children.get(&parent) {
            out.extend(kids.iter().copied().filter(|k| *k != parent));
        }
        i += 1;
        if out.len() > 4096 {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proc_stat_line_reads_even_with_brackets_in_the_name() {
        let p = parse_stat(42, "42 (tmux: server) S 1 42 42 0 -1").unwrap();
        assert_eq!((p.pid, p.ppid, p.name.as_str()), (42, 1, "tmux: server"));
        let q = parse_stat(7, "7 (a) b)) R 3 7").unwrap();
        assert_eq!((q.ppid, q.name.as_str()), (3, "a) b)"));
    }
}
