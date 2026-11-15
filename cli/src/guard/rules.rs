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
use std::fs;
use std::path::PathBuf;

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

    #[test]
    fn kinds_are_cleaned() {
        assert_eq!(clean_kind("Host Name!"), "hostname");
        assert_eq!(clean_kind("…"), "custom");
    }
}
