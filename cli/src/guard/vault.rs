//! Where real values are kept: the only place on the host they are written.
//!
//! A placeholder is `⟦<kind>:<hex>⟧`, the hex an HMAC-SHA256 of the value
//! under this host's key. It shows nothing of the value, and the same value
//! always gets the same placeholder here, so a conversation that mentions an
//! address twice mentions one placeholder twice — which is also what keeps
//! the prompt cache stable from one request to the next.
//!
//! The key and the vault are files under the state folder, mode 0600, on
//! macOS too. The Keychain was the plan, and was dropped for a measured
//! reason of the platform's: a Keychain item's access list names the binary
//! that made it, attache-cli is unsigned and is replaced on every upgrade,
//! so every upgrade would put a password dialog in front of whichever agent
//! hook ran first — on a host reached over SSH, a dialog nobody can answer.

use crate::fsutil::{write_atomic, Lock};
use crate::paths;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
use std::time::Duration;

pub fn dir() -> PathBuf {
    paths::state_dir().join("guard")
}

fn key_path() -> PathBuf {
    dir().join("key")
}

fn vault_path() -> PathBuf {
    dir().join("vault.json")
}

fn private_dir() -> std::io::Result<()> {
    let d = dir();
    fs::create_dir_all(&d)?;
    fs::set_permissions(&d, fs::Permissions::from_mode(0o700))
}

/// This host's key, made on first use from the kernel's random source.
pub fn key() -> Result<Vec<u8>, String> {
    if let Ok(text) = fs::read_to_string(key_path()) {
        if let Some(k) = from_hex(text.trim()) {
            if k.len() == 32 {
                return Ok(k);
            }
        }
        return Err("the guard's key file is damaged; delete it to start a new vault".into());
    }
    private_dir().map_err(|e| e.to_string())?;
    let _lock = Lock::acquire(&dir().join("key.lock"), Duration::from_secs(5))
        .map_err(|e| e.to_string())?
        .ok_or("another process is making the key")?;
    // Made by whoever held the lock before us.
    if let Ok(text) = fs::read_to_string(key_path()) {
        return from_hex(text.trim()).filter(|k| k.len() == 32).ok_or("damaged key".into());
    }
    let mut k = [0u8; 32];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut k))
        .map_err(|e| e.to_string())?;
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(key_path())
        .map_err(|e| e.to_string())?;
    f.write_all(hex(&k).as_bytes()).map_err(|e| e.to_string())?;
    Ok(k.to_vec())
}

pub fn hmac(key: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    inner.update(message);
    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(inner.finalize());
    outer.finalize().into()
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Entry {
    pub value: String,
    pub kind: String,
    /// Which rule found it: `ipv4_lan`, `word:studio-mac` is never written —
    /// a word rule is `word`, a pattern rule `pattern:<name>`.
    pub rule: String,
    /// False for a value the rules let through (allowed, or its detector
    /// off): kept so the owner can see what was let through, never put
    /// into a command.
    pub masked: bool,
    /// False for a mask-only rule.
    pub restore: bool,
    pub first: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct Vault {
    pub entries: BTreeMap<String, Entry>,
}

impl Vault {
    pub fn load() -> Result<Vault, String> {
        match fs::read(vault_path()) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "the guard's vault is damaged; it was left as it is".to_string()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vault::default()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Adds the entries the caller made, under the lock, against the file as
    /// it is now: two agents masking at once each keep the other's.
    pub fn merge(new: &BTreeMap<String, Entry>) -> Result<(), String> {
        if new.is_empty() {
            return Ok(());
        }
        Vault::update(|v| {
            for (token, entry) in new {
                match v.entries.get_mut(token) {
                    // A value let through once and masked now (a rule was
                    // added) becomes a masked one; never the other way.
                    Some(old) if old.value == entry.value => {
                        if entry.masked && !old.masked {
                            old.masked = true;
                            old.restore = entry.restore;
                            old.rule = entry.rule.clone();
                        }
                    }
                    Some(_) => {}
                    None => {
                        v.entries.insert(token.clone(), entry.clone());
                    }
                }
            }
        })
    }

    pub fn update(f: impl FnOnce(&mut Vault)) -> Result<(), String> {
        private_dir().map_err(|e| e.to_string())?;
        let _lock = Lock::acquire(&dir().join("vault.lock"), Duration::from_secs(5))
            .map_err(|e| e.to_string())?
            .ok_or("the vault is busy")?;
        let mut v = Vault::load()?;
        f(&mut v);
        let bytes = serde_json::to_vec(&v).map_err(|e| e.to_string())?;
        let path = vault_path();
        write_atomic(&path, &bytes).map_err(|e| e.to_string())?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())
    }
}

/// The placeholder for `value`: six hex digits, more only when another value
/// of the same kind already holds those six on this host.
pub fn token_for(key: &[u8], kind: &str, value: &str, taken: impl Fn(&str) -> Option<String>) -> String {
    let mut message = Vec::with_capacity(kind.len() + 1 + value.len());
    message.extend_from_slice(kind.as_bytes());
    message.push(0);
    message.extend_from_slice(value.as_bytes());
    let digest = hex(&hmac(key, &message));
    for len in [6, 8, 10, 12, 16] {
        let token = format!("⟦{kind}:{}⟧", &digest[..len]);
        match taken(&token) {
            Some(v) if v != value => continue,
            _ => return token,
        }
    }
    format!("⟦{kind}:{}⟧", &digest[..20])
}

// ── Events ────────────────────────────────────────────────────────────────

fn events_path() -> PathBuf {
    dir().join("events.jsonl")
}

/// What the app's Activity and Not-masked tabs read: one line per value per
/// run, placeholders only. A real value is never written here.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Event {
    pub ts: u64,
    pub agent: String,
    /// `mask`, `pass` (found and let through), `restore`, `block`.
    pub action: String,
    pub kind: String,
    pub rule: String,
    pub token: String,
    /// How many times in that run.
    pub n: u32,
    /// Where: `prompt`, `reply`, `tool:Bash`, `run`, `hook`, `test`.
    #[serde(rename = "where")]
    pub site: String,
}

const EVENTS_MAX: u64 = 4 << 20;

pub fn record(events: &[Event]) {
    if events.is_empty() || private_dir().is_err() {
        return;
    }
    let path = events_path();
    if fs::metadata(&path).map(|m| m.len() > EVENTS_MAX).unwrap_or(false) {
        let _ = fs::rename(&path, dir().join("events.1.jsonl"));
    }
    let mut text = String::new();
    for e in events {
        if let Ok(line) = serde_json::to_string(e) {
            text.push_str(&line);
            text.push('\n');
        }
    }
    // One write, appended: concurrent runs interleave whole lines.
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).mode(0o600).open(&path) {
        let _ = f.write_all(text.as_bytes());
    }
}

/// The last `limit` events, oldest first.
pub fn recent(limit: usize) -> Vec<serde_json::Value> {
    let mut lines: Vec<String> = Vec::new();
    for p in [dir().join("events.1.jsonl"), events_path()] {
        if let Ok(text) = fs::read_to_string(p) {
            lines.extend(text.lines().map(str::to_owned));
        }
    }
    let start = lines.len().saturating_sub(limit);
    lines[start..].iter().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

pub fn clear_events() -> Result<(), String> {
    for p in [dir().join("events.1.jsonl"), events_path()] {
        match fs::remove_file(p) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_rfc_4231_case_2() {
        let mac = hmac(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(hex(&mac), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn tokens_are_stable_and_grow_on_collision() {
        let key = [7u8; 32];
        let a = token_for(&key, "ip", "192.0.2.1", |_| None);
        assert_eq!(a, token_for(&key, "ip", "192.0.2.1", |_| None));
        assert_eq!(a.chars().count(), "⟦ip:⟧".chars().count() + 6);
        let b = token_for(&key, "ip", "192.0.2.1", |t| (t == a).then(|| "192.0.2.2".into()));
        assert_ne!(a, b);
        assert_eq!(b.chars().count(), "⟦ip:⟧".chars().count() + 8);
    }
}
