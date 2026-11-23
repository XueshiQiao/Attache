//! What this program asks of the machine: tmux's panes and screens, the
//! process table, and which files a process holds open. Behind a trait so
//! the discovery rules can be tested against any arrangement of panes and
//! processes; files under the home folder are read directly, and tests point
//! `HOME` at a folder of their own.

use crate::tmux;
use std::collections::HashMap;
#[cfg(not(target_os = "macos"))]
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
    /// The pane's terminal (`/dev/ttys012`): on macOS a program writing to
    /// its screen is a write to this device, which `watch` is told about by
    /// the kernel instead of asking tmux.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub tty: String,
    /// The person renamed the pane (`attache-cli rename`): its title is
    /// theirs, and the program in it can no longer change it.
    pub renamed: bool,
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
            "#{pane_tty}",
            "#{@attache_renamed}",
            "#{pane_title}",
        ]
        .join(&SEP.to_string());
        tmux::lines(&["list-panes", "-a", "-F", &format])
            .iter()
            .filter_map(|line| {
                let f: Vec<&str> = line.splitn(11, SEP).collect();
                if f.len() != 11 || !f[0].starts_with('%') {
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
                    tty: f[8].into(),
                    renamed: !f[9].is_empty(),
                    title: f[10].into(),
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
        #[cfg(target_os = "macos")]
        {
            darwin::processes()
        }
        #[cfg(not(target_os = "macos"))]
        ps_processes()
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
        #[cfg(target_os = "macos")]
        {
            darwin::open_files(pids)
        }
        #[cfg(not(target_os = "macos"))]
        lsof_open_files(pids)
    }

    fn alive(&self, pid: u32) -> bool {
        // SAFETY: signal 0 only checks that the process exists.
        let r = unsafe { libc::kill(pid as libc::pid_t, 0) };
        r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}

/// The process table from `ps`, for a Unix that is neither Linux nor macOS.
#[cfg(not(target_os = "macos"))]
fn ps_processes() -> Vec<Process> {
    // `ucomm` is the short name; `comm` is a full path.
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

/// `lsof` on just these processes, for a Unix that is neither Linux nor
/// macOS.
#[cfg(not(target_os = "macos"))]
fn lsof_open_files(pids: &[u32]) -> Vec<(u32, String)> {
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

/// The process table and open files from the kernel's own calls
/// (libproc), as `ps` and `lsof` read them, without starting either.
///
/// Why it matters: every process started on macOS advances the kernel's
/// boot-wide 32-bit pidversion counter (fork and exec both), and on
/// 2026-11-20 it passed 2^31 after 46 days up; from that second launchd
/// refused every new process its service lookups until a reboot. The
/// watch loops here were the largest steady source: a `ps` and two tmux
/// commands every 0.5 s per watched pane.
#[cfg(target_os = "macos")]
pub mod darwin {
    use super::Process;
    use std::ffi::CStr;
    use std::mem::{size_of, MaybeUninit};

    /// `PROC_PIDFDVNODEPATHINFO` and its reply, from <sys/proc_info.h>;
    /// libc has the parts but not the whole.
    const PROC_PIDFDVNODEPATHINFO: libc::c_int = 2;
    #[repr(C)]
    struct VnodeFdInfoWithPath {
        /// `struct proc_fileinfo`: four u32/i32 and an off_t.
        pfi: [u8; 24],
        pvip: libc::vnode_info_path,
    }

    fn bsdinfo(pid: u32) -> Option<libc::proc_bsdinfo> {
        let mut info = MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: the buffer is a proc_bsdinfo of the size given.
        let n = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size,
            )
        };
        // SAFETY: the kernel filled it when it says it wrote all of it.
        (n == size).then(|| unsafe { info.assume_init() })
    }

    fn name_of(chars: &[libc::c_char]) -> String {
        let bytes: Vec<u8> = chars
            .iter()
            .take_while(|&&c| c != 0)
            .map(|&c| c as u8)
            .collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Every process id, by the call `ps` itself sizes its table with.
    fn all_pids() -> Vec<u32> {
        // SAFETY: a null buffer asks only for the count.
        let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        if count <= 0 {
            return Vec::new();
        }
        // Room for processes started between the two calls.
        let mut pids = vec![0 as libc::c_int; count as usize + 64];
        let bytes = (pids.len() * size_of::<libc::c_int>()) as libc::c_int;
        // SAFETY: the buffer holds `bytes` bytes.
        let n = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
        pids.truncate(n.max(0) as usize);
        pids.into_iter()
            .filter(|&p| p > 0)
            .map(|p| p as u32)
            .collect()
    }

    /// The name `ps -o ucomm=` prints: the kernel's `p_comm`, at most
    /// sixteen characters. `pbi_comm` holds only fifteen of them, so a name
    /// that filled it is taken from `pbi_name`, the longer one it starts
    /// (measured: `attache_cli-d3e` where ps printed `attache_cli-d3eb`).
    fn short_name(info: &libc::proc_bsdinfo) -> String {
        let comm = name_of(&info.pbi_comm);
        let long = name_of(&info.pbi_name);
        let name: String = if comm.len() == libc::MAXCOMLEN - 1 && long.starts_with(&comm) {
            long.chars().take(libc::MAXCOMLEN).collect()
        } else {
            comm
        };
        // Spaces as the `ps` reader left them: split and joined by one.
        name.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    /// What `ps -A -o pid= -o ppid= -o ucomm=` printed. A process that is
    /// gone, or that this user may not ask about, is left out; every
    /// process an agent runs in is this user's.
    pub fn processes() -> Vec<Process> {
        all_pids()
            .into_iter()
            .filter_map(|pid| {
                let info = bsdinfo(pid)?;
                Some(Process {
                    pid,
                    ppid: info.pbi_ppid,
                    name: short_name(&info),
                })
            })
            .collect()
    }

    /// Whether `pid` is a process that has not ended. A process killed
    /// but not yet reaped by its parent is a zombie, which `kill(pid, 0)`
    /// still calls alive: tmux's `respawn-pane -k` leaves one for as long
    /// as it takes tmux to collect it, while the new program is already
    /// drawing.
    pub fn running(pid: u32) -> bool {
        /// `SZOMB` in <sys/proc.h>.
        const SZOMB: u32 = 5;
        bsdinfo(pid).is_some_and(|i| i.pbi_status != SZOMB)
    }

    pub fn parent(pid: u32) -> Option<u32> {
        bsdinfo(pid).map(|i| i.pbi_ppid)
    }

    /// The direct children of `pid`.
    pub fn children(pid: u32) -> Vec<u32> {
        let mut kids = vec![0 as libc::c_int; 256];
        loop {
            let bytes = (kids.len() * size_of::<libc::c_int>()) as libc::c_int;
            // SAFETY: the buffer holds `bytes` bytes.
            let n = unsafe {
                libc::proc_listchildpids(pid as libc::c_int, kids.as_mut_ptr().cast(), bytes)
            };
            if n <= 0 {
                return Vec::new();
            }
            // The call returns a count of pids, and a full buffer may mean
            // more were left out.
            let n = n as usize;
            if n < kids.len() || kids.len() >= 65536 {
                kids.truncate(n.min(kids.len()));
                return kids.into_iter().filter(|&p| p > 0).map(|p| p as u32).collect();
            }
            kids.resize(kids.len() * 4, 0);
        }
    }

    /// `(pid, path)` for every file these processes hold open, as `lsof
    /// -Fpn` named them; sockets, pipes and the like have no path and are
    /// left out, as nothing here asks for them.
    pub fn open_files(pids: &[u32]) -> Vec<(u32, String)> {
        let mut files = Vec::new();
        for &pid in pids {
            let Some(info) = bsdinfo(pid) else { continue };
            let room = info.pbi_nfiles as usize + 16;
            let mut fds: Vec<libc::proc_fdinfo> = Vec::with_capacity(room);
            let bytes = (room * size_of::<libc::proc_fdinfo>()) as libc::c_int;
            // SAFETY: the buffer has room for `room` entries.
            let n = unsafe {
                libc::proc_pidinfo(
                    pid as libc::c_int,
                    libc::PROC_PIDLISTFDS,
                    0,
                    fds.as_mut_ptr().cast(),
                    bytes,
                )
            };
            if n <= 0 {
                continue;
            }
            // SAFETY: the kernel wrote `n` bytes of whole entries.
            unsafe { fds.set_len(n as usize / size_of::<libc::proc_fdinfo>()) };
            for fd in fds.iter().filter(|f| f.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32) {
                let mut vi = MaybeUninit::<VnodeFdInfoWithPath>::zeroed();
                let size = size_of::<VnodeFdInfoWithPath>() as libc::c_int;
                // SAFETY: the buffer is the struct the flavour fills.
                let got = unsafe {
                    libc::proc_pidfdinfo(
                        pid as libc::c_int,
                        fd.proc_fd,
                        PROC_PIDFDVNODEPATHINFO,
                        vi.as_mut_ptr().cast(),
                        size,
                    )
                };
                if got != size {
                    continue;
                }
                // SAFETY: filled in full, and the path is NUL-terminated
                // within its MAXPATHLEN bytes (zeroed beforehand besides).
                let path = unsafe {
                    let vi = vi.assume_init();
                    let raw: &[libc::c_char; 1024] = std::mem::transmute(&vi.pvip.vip_path);
                    CStr::from_ptr(raw.as_ptr()).to_string_lossy().into_owned()
                };
                if !path.is_empty() {
                    files.push((pid, path));
                }
            }
        }
        files
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
    #[cfg(target_os = "macos")]
    use std::process::Command;

    #[test]
    fn a_proc_stat_line_reads_even_with_brackets_in_the_name() {
        let p = parse_stat(42, "42 (tmux: server) S 1 42 42 0 -1").unwrap();
        assert_eq!((p.pid, p.ppid, p.name.as_str()), (42, 1, "tmux: server"));
        let q = parse_stat(7, "7 (a) b)) R 3 7").unwrap();
        assert_eq!((q.ppid, q.name.as_str()), (3, "a) b)"));
    }

    /// libproc must read what `ps` and `lsof` read, or `agents` finds other
    /// agents than it did: compared on this machine's own process table.
    #[cfg(target_os = "macos")]
    #[test]
    fn libproc_reads_what_ps_and_lsof_read() {
        let out = Command::new("ps")
            .args(["-A", "-o", "pid=", "-o", "ppid=", "-o", "ucomm="])
            .output()
            .unwrap();
        let ps: HashMap<u32, (u32, String)> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| {
                let mut it = l.split_whitespace();
                let pid = it.next()?.parse().ok()?;
                let ppid = it.next()?.parse().ok()?;
                Some((pid, (ppid, it.collect::<Vec<_>>().join(" "))))
            })
            .collect();
        let mine = darwin::processes();
        let me = std::process::id();
        let mut compared = 0;
        for p in &mine {
            if let Some((ppid, name)) = ps.get(&p.pid) {
                assert_eq!((p.ppid, p.name.as_str()), (*ppid, name.as_str()), "pid {}", p.pid);
                compared += 1;
            }
        }
        assert!(compared > 50, "only {compared} processes in both");
        assert!(mine.iter().any(|p| p.pid == me));
        assert!(darwin::children(std::os::unix::process::parent_id()).contains(&me));

        let file = tempfile::NamedTempFile::new().unwrap();
        let held = file.path().canonicalize().unwrap();
        let files = darwin::open_files(&[me]);
        assert!(
            files.iter().any(|(pid, path)| *pid == me && std::path::Path::new(path) == held),
            "{held:?} not in {files:?}"
        );
    }
}
