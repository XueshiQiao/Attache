//! Files shared by processes that never talk to each other.
//!
//! Every `attache-cli` invocation is its own process, started by whoever
//! needs it: Claude for a status line or a hook, a person for `send`, the
//! phone or the desktop for everything else. They meet only in files, so
//! two rules hold everywhere:
//!
//! - A file is replaced, never edited in place: written beside itself and
//!   renamed over, so a reader sees the old whole file or the new whole file.
//! - A read-modify-write takes a lock first. The lock is the kernel's
//!   (`flock`), so it goes away with its process, however that process ends.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

/// Writes `bytes` to `path` so that no reader ever sees half of it.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no parent"))?;
    fs::create_dir_all(dir)?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    {
        let mut f = File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    // A config the person may have made private stays private.
    if let Ok(meta) = fs::metadata(path) {
        let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(meta.permissions().mode()));
    }
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

/// An exclusive lock on `path` (created if missing), held until dropped.
pub struct Lock {
    _file: File,
}

impl Lock {
    /// Waits up to `wait` for the lock; `None` when someone else kept it.
    /// Callers on an agent's path (status line, hooks) pass a short wait and
    /// give up rather than stall the agent.
    pub fn acquire(path: &Path, wait: Duration) -> io::Result<Option<Lock>> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)?;
        let deadline = Instant::now() + wait;
        loop {
            // SAFETY: flock on a descriptor this function owns.
            let r = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if r == 0 {
                return Ok(Some(Lock { _file: file }));
            }
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EWOULDBLOCK) {
                return Err(err);
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
}

/// An agent's id for a session or conversation, safe to use as a file name:
/// it comes from JSON an agent handed over, and a `/` or `..` in it would
/// otherwise write outside the state folder.
pub fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replaced_file_keeps_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.json");
        fs::write(&p, "old").unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o600)).unwrap();
        write_atomic(&p, b"new").unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "new");
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // Nothing left beside it.
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn a_held_lock_makes_the_next_one_wait_and_give_up() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("x.lock");
        let first = Lock::acquire(&p, Duration::ZERO).unwrap();
        assert!(first.is_some());
        let started = Instant::now();
        assert!(Lock::acquire(&p, Duration::from_millis(50))
            .unwrap()
            .is_none());
        assert!(started.elapsed() >= Duration::from_millis(50));
        drop(first);
        assert!(Lock::acquire(&p, Duration::ZERO).unwrap().is_some());
    }

    #[test]
    fn only_plain_ids_name_files() {
        assert!(safe_id("c94cb7d8-1e11-4a15-b95d-b432b56207bb"));
        assert!(!safe_id("../etc"));
        assert!(!safe_id("a/b"));
        assert!(!safe_id(""));
    }
}
