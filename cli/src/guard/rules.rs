//! The rules: what the guard looks for, and what it does with each find.
//!
//! They live in `~/.config/attache-guard.toml`, one file per host, beside
//! `attache-projects.toml` and for the same reason: an agent runs on that
//! host, so the guard runs there, and both clients and a person at the
//! keyboard must read the same rules. The file is read on every run, so an
//! edit applies to the next row an agent stores, with no agent restarted.
//!
//! A missing file means the defaults: everything on but loopback. A file
//! that does not parse is not "no rules": every caller that masks refuses to
//! pass content through unmasked and says why (see `Rules::load`).

use crate::fsutil::write_atomic;
use crate::paths;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::SystemTime;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Replaced by a placeholder; a command or a file write the agent makes
    /// with the placeholder gets the real value back.
    #[default]
    Mask,
    /// Replaced, and never put back: the agent can mention it, not use it.
    MaskOnly,
    /// The whole prompt or tool result is withheld.
    Block,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Detect {
    /// Every IPv4 address that is not one of the kinds below.
    pub ipv4_public: bool,
    /// 10/8, 172.16/12, 192.168/16, 169.254/16.
    pub ipv4_lan: bool,
    /// 100.64/10, where Tailscale and other CGNAT networks put devices.
    pub ipv4_tailscale: bool,
    /// 127/8. Off by default: it names no machine.
    pub ipv4_loopback: bool,
    pub ipv6_global: bool,
    /// fc00::/7, which Tailscale uses too.
    pub ipv6_ula: bool,
    pub ipv6_link_local: bool,
    pub mac: bool,
    pub email: bool,
    pub phone: bool,
    /// API keys, tokens and private keys in their well-known shapes.
    pub secrets: bool,
}

impl Default for Detect {
    fn default() -> Self {
        Detect {
            ipv4_public: true,
            ipv4_lan: true,
            ipv4_tailscale: true,
            ipv4_loopback: false,
            ipv6_global: true,
            ipv6_ula: true,
            ipv6_link_local: true,
            mac: true,
            email: true,
            phone: true,
            secrets: true,
        }
    }
}

impl Detect {
    pub fn get(&self, id: &str) -> Option<bool> {
        Some(match id {
            "ipv4_public" => self.ipv4_public,
            "ipv4_lan" => self.ipv4_lan,
            "ipv4_tailscale" => self.ipv4_tailscale,
            "ipv4_loopback" => self.ipv4_loopback,
            "ipv6_global" => self.ipv6_global,
            "ipv6_ula" => self.ipv6_ula,
            "ipv6_link_local" => self.ipv6_link_local,
            "mac" => self.mac,
            "email" => self.email,
            "phone" => self.phone,
            "secrets" => self.secrets,
            _ => return None,
        })
    }
}

/// A word the person names: a host name, a real name, an account.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct WordRule {
    pub text: String,
    pub ignore_case: bool,
    pub enabled: bool,
    pub action: Action,
}

impl Default for WordRule {
    fn default() -> Self {
        WordRule { text: String::new(), ignore_case: true, enabled: true, action: Action::Mask }
    }
}

/// A regular expression the person writes. With a capture group, only the
/// first group is replaced (`token=(\w+)` keeps `token=`).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct PatternRule {
    pub name: String,
    pub pattern: String,
    /// The word in the placeholder, `⟦<kind>:…⟧`: a-z and 0-9, at most 12.
    pub kind: String,
    pub enabled: bool,
    pub action: Action,
}

impl Default for PatternRule {
    fn default() -> Self {
        PatternRule {
            name: String::new(),
            pattern: String::new(),
            kind: "custom".into(),
            enabled: true,
            action: Action::Mask,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Rules {
    /// The master switch. Off, every agent's content passes as it is.
    pub enabled: bool,
    /// Unix seconds until which the guard stands aside (`guard pause`).
    pub paused_until: u64,
    /// Values never masked, compared without regard to case: a public
    /// resolver, a project's own domain, a git host's SSH user.
    pub allow: Vec<String>,
    pub detect: Detect,
    #[serde(rename = "word")]
    pub words: Vec<WordRule>,
    #[serde(rename = "pattern")]
    pub patterns: Vec<PatternRule>,
}

impl Default for Rules {
    fn default() -> Self {
        Rules {
            enabled: true,
            paused_until: 0,
            // Shaped like email addresses and in every git remote and
            // commit trailer an agent reads; masking them makes `git push`
            // output unreadable and protects no one.
            allow: vec![
                "git@github.com".into(),
                "git@gitlab.com".into(),
                "git@bitbucket.org".into(),
                "noreply@anthropic.com".into(),
                "noreply@github.com".into(),
            ],
            detect: Detect::default(),
            words: Vec::new(),
            patterns: Vec::new(),
        }
    }
}

pub fn path() -> PathBuf {
    paths::home().join(".config/attache-guard.toml")
}

const HEADER: &str = "\
# Attaché privacy guard: what is kept out of every agent's conversation on
# this host. Edited from Attaché's settings (Privacy Guard) or by hand; read
# on every run, so a change applies at once. Saving from the app rewrites
# this file, comments included.
";

impl Rules {
    /// The rules in force. `Err` when the file is there and unreadable:
    /// the callers that mask must not read that as "nothing to mask".
    pub fn load() -> Result<Rules, String> {
        match fs::read_to_string(path()) {
            Ok(text) => Rules::parse(&text),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Rules::default()),
            Err(e) => Err(format!("{}: {e}", path().display())),
        }
    }

    pub fn parse(text: &str) -> Result<Rules, String> {
        toml::from_str::<Rules>(text).map_err(|e| format!("attache-guard.toml: {}", e.message()))
    }

    pub fn to_toml(&self) -> Result<String, String> {
        let body = toml::to_string(self).map_err(|e| e.to_string())?;
        Ok(format!("{HEADER}\n{body}"))
    }

    pub fn save(&self) -> Result<(), String> {
        let text = self.to_toml()?;
        write_atomic(&path(), text.as_bytes()).map_err(|e| e.to_string())
    }

    /// Whether the guard masks right now: on, and not paused.
    pub fn active(&self, now: u64) -> bool {
        self.enabled && self.paused_until <= now
    }

    pub fn allows(&self, value: &str) -> bool {
        self.allow.iter().any(|a| a.trim().eq_ignore_ascii_case(value))
    }

    /// Writes these rules where a sandboxed `guard run` can read them, and
    /// returns the name to hand it: the SHA-256 of the bytes written.
    ///
    /// agy's `--sandbox` denies reads of everything under `~/.config`, with a
    /// fixed list of exceptions built into agy (measured 2026-11-23 on agy
    /// 1.5.14: the profile it writes for each command opens `~/.config/bat`
    /// and nothing else there, while `~/.local/state` stays readable). The
    /// hook runs outside that sandbox and the command it wraps runs inside,
    /// so the hook reads the rules and leaves this copy beside the vault.
    /// Only the digest goes into the command, so the rules' words are not in
    /// the text the model is shown. That is all it buys: the copy, like the
    /// vault, sits where the sandbox can read, and a command that encodes a
    /// file (base64) gets it past the output mask. The guard keeps values
    /// out of what an agent is handed; it does not hold off a model trying
    /// to get round it.
    ///
    /// The digest is also the check. The sandbox lets the model's commands
    /// write the home folder, so a copy could be edited — to switch the guard
    /// off, say — or swapped for a link or a pipe. `load_snapshot` refuses
    /// bytes that do not hash to the name the hook put in the command, and
    /// the hook rewrites a copy that is not exactly what it would write.
    pub fn snapshot(&self) -> Result<String, String> {
        let bytes = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        let digest = super::vault::hex(&Sha256::digest(&bytes));
        let path = snapshot_path(&digest);
        super::vault::private_dir().map_err(|e| e.to_string())?;
        // Kept fresh so pruning keeps the copies in use; a copy that cannot
        // be freshened is written again rather than left to be pruned.
        let fresh = match open_copy(&path, true) {
            Ok((f, on_disk)) => on_disk == bytes && f.set_modified(SystemTime::now()).is_ok(),
            Err(_) => false,
        };
        if !fresh {
            // The rename replaces whatever is at the path, link or pipe
            // included, never what a link points to.
            write_atomic(&path, &bytes).map_err(|e| e.to_string())?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        }
        prune_snapshots(&digest);
        Ok(digest)
    }

    /// The rules a hook wrote with `snapshot`. `Err` when the copy is gone,
    /// or its bytes no longer hash to `digest`: the caller refuses to run.
    pub fn load_snapshot(digest: &str) -> Result<Rules, String> {
        if !is_digest(digest) {
            return Err("the rules snapshot is not named by a digest".into());
        }
        let (_, bytes) = open_copy(&snapshot_path(digest), false)
            .map_err(|e| format!("the rules snapshot could not be read: {e}"))?;
        if super::vault::hex(&Sha256::digest(&bytes)) != digest {
            return Err("the rules snapshot was changed after the hook wrote it".into());
        }
        serde_json::from_slice(&bytes).map_err(|e| format!("the rules snapshot is damaged: {e}"))
    }
}

/// How many rule copies to keep. A copy is used within a moment of being
/// written; the extra ones only cover commands still starting while the
/// rules were edited several times in a row.
const SNAPSHOTS_KEPT: usize = 8;

/// Far larger than any rules file; a copy past it is not one the hook wrote.
const SNAPSHOT_MAX: u64 = 4 << 20;

fn is_digest(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn snapshot_path(digest: &str) -> PathBuf {
    super::vault::dir().join(format!("rules-{digest}.json"))
}

/// Opens a rule copy and reads it, refusing anything but a plain file of a
/// sane size: the sandbox can put a link to `/dev/zero` or a pipe nobody
/// writes in its place, and the hook outside must neither follow the one
/// nor wait on the other.
fn open_copy(path: &std::path::Path, write: bool) -> std::io::Result<(fs::File, Vec<u8>)> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let f = fs::File::options()
        .read(true)
        .write(write)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = f.metadata()?;
    if !meta.is_file() || meta.len() > SNAPSHOT_MAX {
        return Err(std::io::Error::other("not a rules copy"));
    }
    let mut bytes = Vec::new();
    (&f).take(SNAPSHOT_MAX + 1).read_to_end(&mut bytes)?;
    Ok((f, bytes))
}

/// Removes the oldest rule copies past `SNAPSHOTS_KEPT`, never `keep`. Only
/// names this program writes, `rules-<64 hex>.json`, are counted, and a time
/// in the future counts as the oldest: otherwise a few files the sandbox
/// dated ahead would have every copy in use pruned on each run.
fn prune_snapshots(keep: &str) {
    let Ok(dir) = fs::read_dir(super::vault::dir()) else { return };
    let now = SystemTime::now();
    let mut copies: Vec<(SystemTime, String)> = dir
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let digest = name.strip_prefix("rules-")?.strip_suffix(".json")?;
            if !is_digest(digest) || digest == keep {
                return None;
            }
            let modified = e.metadata().ok()?.modified().ok()?;
            Some((if modified > now { SystemTime::UNIX_EPOCH } else { modified }, name))
        })
        .collect();
    copies.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let dir = super::vault::dir();
    for (_, name) in copies.into_iter().skip(SNAPSHOTS_KEPT - 1) {
        let _ = fs::remove_file(dir.join(name));
    }
}

/// A placeholder kind as the rules may name one.
pub fn clean_kind(kind: &str) -> String {
    let k: String = kind
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .take(12)
        .collect();
    if k.is_empty() {
        "custom".into()
    } else {
        k
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_round_trip_through_toml() {
        let rules = Rules {
            words: vec![WordRule { text: "studio-mac".into(), ..Default::default() }],
            patterns: vec![PatternRule {
                name: "ticket".into(),
                pattern: r"TCK-\d+".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let text = rules.to_toml().unwrap();
        assert_eq!(Rules::parse(&text).unwrap(), rules);
    }

    #[test]
    fn a_partial_file_takes_defaults_for_the_rest() {
        let rules = Rules::parse("[detect]\nemail = false\n").unwrap();
        assert!(!rules.detect.email);
        assert!(rules.detect.ipv4_lan);
        assert!(rules.enabled);
    }

    #[test]
    fn a_broken_file_is_an_error_not_defaults() {
        assert!(Rules::parse("enabled = maybe").is_err());
    }

    fn with_home<T>(f: impl FnOnce() -> T) -> T {
        let dir = tempfile::tempdir().unwrap();
        paths::TEST_HOME.with(|h| *h.borrow_mut() = Some(dir.path().to_path_buf()));
        let out = f();
        paths::TEST_HOME.with(|h| *h.borrow_mut() = None);
        out
    }

    fn named(word: &str) -> Rules {
        Rules { words: vec![WordRule { text: word.into(), ..Default::default() }], ..Default::default() }
    }

    #[test]
    fn a_snapshot_reads_back_as_the_same_rules_and_is_private() {
        with_home(|| {
            let rules = named("studio-mac");
            let digest = rules.snapshot().unwrap();
            assert_eq!(Rules::load_snapshot(&digest).unwrap(), rules);
            let mode = fs::metadata(snapshot_path(&digest)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
            assert_eq!(rules.snapshot().unwrap(), digest, "the same rules, the same copy");
        });
    }

    #[test]
    fn an_edited_snapshot_is_refused_and_the_hook_puts_it_back() {
        with_home(|| {
            let rules = named("studio-mac");
            let digest = rules.snapshot().unwrap();
            let off = Rules { enabled: false, ..rules.clone() };
            fs::write(snapshot_path(&digest), serde_json::to_vec(&off).unwrap()).unwrap();
            assert!(Rules::load_snapshot(&digest).is_err());
            assert_eq!(rules.snapshot().unwrap(), digest);
            assert_eq!(Rules::load_snapshot(&digest).unwrap(), rules);
        });
    }

    #[test]
    fn a_snapshot_is_named_by_a_digest_and_nothing_else() {
        with_home(|| {
            assert!(Rules::load_snapshot("../../.config/attache-guard").is_err());
            assert!(Rules::load_snapshot("abc").is_err());
            assert!(Rules::load_snapshot(&"0".repeat(64)).is_err(), "a digest with no copy");
            let digest = named("x").snapshot().unwrap();
            assert!(Rules::load_snapshot(&digest.to_uppercase()).is_err(), "upper-case hex is not a name we write");
        });
    }

    fn date(path: &std::path::Path, when: SystemTime) {
        fs::File::options().write(true).open(path).unwrap().set_modified(when).unwrap();
    }

    #[test]
    fn the_oldest_snapshots_by_time_are_pruned_and_the_current_one_kept() {
        with_home(|| {
            let now = SystemTime::now();
            // Written directly: `snapshot` would prune while they are made.
            super::super::vault::private_dir().unwrap();
            let digests: Vec<String> = (0..12)
                .map(|i| {
                    let bytes = serde_json::to_vec(&named(&format!("word-{i}"))).unwrap();
                    let d = super::super::vault::hex(&Sha256::digest(&bytes));
                    fs::write(snapshot_path(&d), bytes).unwrap();
                    d
                })
                .collect();
            // Dated against the order they were made: word-0 the newest.
            for (i, d) in digests.iter().enumerate() {
                date(&snapshot_path(d), now - std::time::Duration::from_secs(60 * (i as u64 + 1)));
            }
            named("word-11").snapshot().unwrap();
            for (i, d) in digests.iter().enumerate() {
                let kept = snapshot_path(d).exists();
                assert_eq!(kept, i < SNAPSHOTS_KEPT - 1 || i == 11, "word-{i}");
            }
        });
    }

    #[test]
    fn files_dated_ahead_cannot_push_the_copies_in_use_out() {
        with_home(|| {
            let in_use: Vec<String> = (0..3).map(|i| named(&format!("word-{i}")).snapshot().unwrap()).collect();
            let dir = super::super::vault::dir();
            let ahead = SystemTime::now() + std::time::Duration::from_secs(86_400);
            for i in 0..SNAPSHOTS_KEPT {
                let fake = dir.join(format!("rules-{:064x}.json", i + 1));
                fs::write(&fake, "{}").unwrap();
                date(&fake, ahead);
            }
            fs::write(dir.join("rules-not-a-digest.json"), "{}").unwrap();
            named("word-3").snapshot().unwrap();
            for d in &in_use {
                assert!(Rules::load_snapshot(d).is_ok());
            }
            assert!(dir.join("rules-not-a-digest.json").exists(), "a name we never write is not ours to remove");
        });
    }

    #[test]
    fn a_link_or_a_pipe_in_place_of_a_copy_is_refused_and_replaced() {
        with_home(|| {
            let rules = named("studio-mac");
            let digest = rules.snapshot().unwrap();
            let path = snapshot_path(&digest);
            let elsewhere = super::super::vault::dir().join("../elsewhere.json");
            fs::write(&elsewhere, serde_json::to_vec(&rules).unwrap()).unwrap();
            date(&elsewhere, SystemTime::UNIX_EPOCH);

            fs::remove_file(&path).unwrap();
            std::os::unix::fs::symlink(&elsewhere, &path).unwrap();
            assert!(Rules::load_snapshot(&digest).is_err(), "a link is not followed");
            assert_eq!(rules.snapshot().unwrap(), digest);
            assert!(!fs::symlink_metadata(&path).unwrap().file_type().is_symlink());
            assert_eq!(fs::metadata(&elsewhere).unwrap().modified().unwrap(), SystemTime::UNIX_EPOCH, "what the link named was not touched");

            fs::remove_file(&path).unwrap();
            let c = std::ffi::CString::new(path.to_string_lossy().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
            assert!(Rules::load_snapshot(&digest).is_err(), "a pipe is refused, not waited on");
            assert_eq!(rules.snapshot().unwrap(), digest);
            assert_eq!(Rules::load_snapshot(&digest).unwrap(), rules);
        });
    }

    #[test]
    fn kinds_are_cleaned() {
        assert_eq!(clean_kind("Host Name!"), "hostname");
        assert_eq!(clean_kind("…"), "custom");
    }
}
