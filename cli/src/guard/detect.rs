//! Finding private values in text, and swapping them for placeholders and
//! back.
//!
//! Everything works on bytes (`regex::bytes`), because `guard run` masks a
//! command's raw output and a lossy decode would corrupt whatever binary a
//! command prints. The values themselves are always UTF-8 in practice: the
//! built-in shapes are ASCII and a word rule's text is a Rust string.
//!
//! Two directions fail differently, as in `TerminalReply` on the app's side:
//! a value missed reaches a model and a transcript, which cannot be undone;
//! a version string or a time masked by mistake is a nuisance the owner sees
//! in the Activity tab. So the shapes lean towards masking, and each place
//! they are known to bite ordinary text (times, versions, `icon@2x.png`, Rust
//! paths) has a case in the tests.

use super::rules::{clean_kind, Action, Rules};
use super::vault::{self, Entry, Event, Vault};
use regex::bytes::{Regex, RegexBuilder};
use std::collections::{BTreeMap, HashMap};
use std::net::Ipv6Addr;
use std::sync::OnceLock;

/// What happens to one find.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Mask { restore: bool },
    Block,
    /// Found, and let through: allowed, or its detector is off.
    Pass,
}

#[derive(Clone, Debug)]
pub struct Hit {
    pub start: usize,
    pub end: usize,
    pub kind: String,
    pub rule: String,
    pub verdict: Verdict,
    /// Words and patterns win an overlap against the built-in shapes.
    priority: u8,
}

struct Shapes {
    ipv4: Regex,
    ipv6: Regex,
    mac: Regex,
    email: Regex,
    phone_intl: Regex,
    phone_cn: Regex,
    secrets: Vec<Regex>,
    assignment: Regex,
    placeholder: Regex,
}

fn shapes() -> &'static Shapes {
    static S: OnceLock<Shapes> = OnceLock::new();
    S.get_or_init(|| {
        let r = |p: &str| Regex::new(p).expect("built-in pattern");
        Shapes {
            ipv4: r(r"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"),
            ipv6: r(r"[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(?:[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})?"),
            mac: r(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}"),
            email: r(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,24}"),
            phone_intl: r(r"\+[0-9]{1,3}[ \-]?(?:\([0-9]{1,4}\)[ \-]?)?[0-9]{2,4}(?:[ \-]?[0-9]{2,4}){1,4}"),
            phone_cn: r(r"1[3-9][0-9]{9}"),
            secrets: [
                r"sk-ant-[A-Za-z0-9_\-]{20,}",
                r"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}",
                r"gh[pousr]_[A-Za-z0-9]{30,}",
                r"github_pat_[A-Za-z0-9_]{30,}",
                r"glpat-[A-Za-z0-9_\-]{20,}",
                r"AKIA[0-9A-Z]{16}",
                r"xox[abprs]-[A-Za-z0-9\-]{10,}",
                r"AIza[0-9A-Za-z_\-]{35}",
                r"tskey-[A-Za-z0-9\-]{16,}",
                r"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}",
                r"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
            ]
            .iter()
            .map(|p| r(p))
            .collect(),
            assignment: r(r#"(?i)(?:password|passwd|secret|token|api[_\-]?key|access[_\-]?key)["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9_\-+/=]{12,})"#),
            placeholder: r(r"⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧"),
        }
    })
}

pub fn placeholder_regex() -> &'static Regex {
    &shapes().placeholder
}

fn is_alnum(b: Option<&u8>) -> bool {
    b.is_some_and(|b| b.is_ascii_alphanumeric())
}

fn is_digit(b: Option<&u8>) -> bool {
    b.is_some_and(|b| b.is_ascii_digit())
}

/// The kinds of address, with the detector switch each answers to; `None`
/// for addresses that name no machine and are never candidates.
fn ipv4_class(o: [u8; 4]) -> Option<&'static str> {
    Some(match o {
        [0, ..] | [255, ..] => return None,
        [127, ..] => "ipv4_loopback",
        [10, ..] | [192, 168, ..] | [169, 254, ..] => "ipv4_lan",
        [172, b, ..] if (16..=31).contains(&b) => "ipv4_lan",
        [100, b, ..] if (64..=127).contains(&b) => "ipv4_tailscale",
        _ => "ipv4_public",
    })
}

fn ipv6_class(a: &Ipv6Addr) -> Option<&'static str> {
    let s = a.segments();
    if a.is_unspecified() || a.is_loopback() {
        return None;
    }
    if let Some(v4) = a.to_ipv4_mapped() {
        return ipv4_class(v4.octets());
    }
    Some(match s[0] {
        x if x & 0xffc0 == 0xfe80 => "ipv6_link_local",
        x if x & 0xfe00 == 0xfc00 => "ipv6_ula",
        _ => "ipv6_global",
    })
}

/// Common file extensions and systemd unit kinds, which `icon@2x.png` and
/// `getty@tty1.service` would otherwise make into email addresses.
const NOT_TLDS: [&str; 44] = [
    "png", "jpg", "jpeg", "gif", "svg", "webp", "pdf", "ico", "heic", "js", "ts", "css", "mjs", "cjs", "tsx", "jsx",
    "scss", "map", "json", "yaml", "yml", "toml", "txt", "md", "log", "lock", "sh", "py", "rs", "go", "swift", "kt",
    "java", "html", "zip", "gz", "tar", "service", "socket", "target", "timer", "mount", "path", "slice",
];

/// The built-in finds in `text`: (start, end, kind, detector).
fn builtin(text: &[u8]) -> Vec<(usize, usize, &'static str, &'static str)> {
    let s = shapes();
    let mut out = Vec::new();

    for m in s.ipv4.find_iter(text) {
        let (a, b) = (m.start(), m.end());
        // Part of a longer dotted run (a version, an OID) or of a number.
        let before = a.checked_sub(1).and_then(|i| text.get(i));
        // `v1.2.3.4` is a version.
        if is_digit(before)
            || matches!(before, Some(b'.' | b'v' | b'V'))
            || is_digit(text.get(b))
            || (text.get(b) == Some(&b'.') && is_digit(text.get(b + 1)))
        {
            continue;
        }
        let parts: Vec<u16> = m.as_bytes().split(|&c| c == b'.').filter_map(|p| std::str::from_utf8(p).ok()?.parse().ok()).collect();
        if parts.len() != 4 || parts.iter().any(|&p| p > 255) {
            continue;
        }
        let octets = [parts[0] as u8, parts[1] as u8, parts[2] as u8, parts[3] as u8];
        if let Some(class) = ipv4_class(octets) {
            out.push((a, b, "ip", class));
        }
    }

    for m in s.ipv6.find_iter(text) {
        let (a, mut b) = (m.start(), m.end());
        let mut cand = m.as_bytes();
        // A sentence's colon after an address.
        while cand.len() > 2 && cand.ends_with(b":") && !cand.ends_with(b"::") {
            cand = &cand[..cand.len() - 1];
            b -= 1;
        }
        if !cand.iter().any(u8::is_ascii_digit) {
            continue;
        }
        // `arr[1::2]`, `a::b1`: a slice or a path, not an address. An
        // address written short has a group of three or more digits
        // (`fe80::1`, `2001:db8::`), or is written long.
        let groups: Vec<&[u8]> = cand.split(|&c| c == b':').filter(|g| !g.is_empty()).collect();
        if groups.len() < 4 && !groups.iter().any(|g| g.len() >= 3) {
            continue;
        }
        let before = a.checked_sub(1).and_then(|i| text.get(i));
        if is_alnum(before) || is_alnum(text.get(b)) || before == Some(&b'.') {
            continue;
        }
        let Some(addr) = std::str::from_utf8(cand).ok().and_then(|c| c.parse::<Ipv6Addr>().ok()) else {
            continue;
        };
        if let Some(class) = ipv6_class(&addr) {
            let kind = if class.starts_with("ipv4") { "ip" } else { "ip6" };
            out.push((a, b, kind, class));
        }
    }

    for m in s.mac.find_iter(text) {
        let (a, b) = (m.start(), m.end());
        let before = a.checked_sub(1).and_then(|i| text.get(i));
        let after = text.get(b);
        let joins = |c: Option<&u8>| c.is_some_and(|c| c.is_ascii_hexdigit() || *c == b':' || *c == b'-');
        if joins(before) || joins(after) {
            continue;
        }
        let hex: Vec<u8> = m.as_bytes().iter().copied().filter(u8::is_ascii_hexdigit).collect();
        if hex.iter().all(|&c| c == b'0') || hex.iter().all(|&c| c == b'f' || c == b'F') {
            continue;
        }
        out.push((a, b, "mac", "mac"));
    }

    for m in s.email.find_iter(text) {
        let v = m.as_bytes();
        let tld = v.rsplit(|&c| c == b'.').next().unwrap_or_default().to_ascii_lowercase();
        if NOT_TLDS.iter().any(|t| t.as_bytes() == tld.as_slice()) {
            continue;
        }
        out.push((m.start(), m.end(), "email", "email"));
    }

    for m in s.phone_intl.find_iter(text) {
        let (a, b) = (m.start(), m.end());
        let digits = m.as_bytes().iter().filter(|c| c.is_ascii_digit()).count();
        // `+2026-11-15T08:00` at the start of a diff line is a date.
        if !(8..=15).contains(&digits) || is_alnum(a.checked_sub(1).and_then(|i| text.get(i))) || is_alnum(text.get(b)) {
            continue;
        }
        out.push((a, b, "phone", "phone"));
    }
    for m in s.phone_cn.find_iter(text) {
        let (a, b) = (m.start(), m.end());
        let before = a.checked_sub(1).and_then(|i| text.get(i));
        // `3.14159265359`: decimals, not a number to call.
        if is_alnum(before) || matches!(before, Some(b'.' | b',')) || is_alnum(text.get(b)) || text.get(b) == Some(&b'.') {
            continue;
        }
        out.push((a, b, "phone", "phone"));
    }

    for re in &s.secrets {
        for m in re.find_iter(text) {
            if is_alnum(m.start().checked_sub(1).and_then(|i| text.get(i))) {
                continue;
            }
            out.push((m.start(), m.end(), "key", "secrets"));
        }
    }
    for c in s.assignment.captures_iter(text) {
        let Some(g) = c.get(1) else { continue };
        let v = g.as_bytes();
        // `token = encode(x)` is code, not a value.
        if text.get(g.end()) == Some(&b'(') || text.get(g.end()) == Some(&b'.') {
            continue;
        }
        if v.iter().any(u8::is_ascii_digit) && v.iter().any(u8::is_ascii_alphabetic) {
            out.push((g.start(), g.end(), "key", "secrets"));
        }
    }
    out
}

struct Custom {
    re: Regex,
    kind: String,
    rule: String,
    action: Action,
    group: bool,
}

/// The rules made ready for one run, with what it found along the way.
pub struct Engine {
    rules: Rules,
    active: bool,
    customs: Vec<Custom>,
    /// Why a pattern rule could not be used: named in `guard rules` and
    /// `guard test`, and the rule is skipped.
    pub errors: Vec<(usize, String)>,
    key: Vec<u8>,
    vault: Vault,
    by_value: HashMap<(String, String), String>,
    new_entries: BTreeMap<String, Entry>,
    tally: BTreeMap<(String, String), (String, String, u32)>,
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Engine {
    pub fn load() -> Result<Engine, String> {
        Engine::new(super::rules::Rules::load()?, vault::key()?, Vault::load()?)
    }

    pub fn new(rules: Rules, key: Vec<u8>, vault: Vault) -> Result<Engine, String> {
        let mut customs = Vec::new();
        let mut errors = Vec::new();
        for w in rules.words.iter().filter(|w| w.enabled) {
            let text = w.text.trim();
            if text.chars().count() < 2 {
                continue;
            }
            let re = RegexBuilder::new(&regex::escape(text))
                .case_insensitive(w.ignore_case)
                .build()
                .map_err(|e| e.to_string())?;
            customs.push(Custom { re, kind: "word".into(), rule: "word".into(), action: w.action, group: false });
        }
        for (i, p) in rules.patterns.iter().enumerate() {
            if !p.enabled || p.pattern.is_empty() {
                continue;
            }
            match RegexBuilder::new(&p.pattern).size_limit(1 << 20).dfa_size_limit(1 << 21).build() {
                Ok(re) => {
                    let group = re.captures_len() > 1;
                    customs.push(Custom {
                        re,
                        kind: clean_kind(&p.kind),
                        rule: format!("pattern:{}", p.name),
                        action: p.action,
                        group,
                    });
                }
                Err(e) => errors.push((i, e.to_string().lines().last().unwrap_or("invalid").trim().to_owned())),
            }
        }
        let mut by_value = HashMap::new();
        for (token, e) in &vault.entries {
            by_value.insert((e.kind.clone(), e.value.clone()), token.clone());
        }
        let active = rules.active(now());
        Ok(Engine {
            rules,
            active,
            customs,
            errors,
            key,
            vault,
            by_value,
            new_entries: BTreeMap::new(),
            tally: BTreeMap::new(),
        })
    }

    pub fn active(&self) -> bool {
        self.active
    }

    /// Every find, overlaps resolved, in order. Text already masked is never
    /// looked into: a word rule must not match inside a placeholder.
    pub fn find(&self, text: &[u8]) -> Vec<Hit> {
        let held: Vec<(usize, usize)> = placeholder_regex().find_iter(text).map(|m| (m.start(), m.end())).collect();
        let mut hits = Vec::new();
        for (start, end, kind, det) in builtin(text) {
            let value = String::from_utf8_lossy(&text[start..end]);
            let on = self.rules.detect.get(det).unwrap_or(true);
            if det == "ipv4_loopback" && !on {
                continue;
            }
            let verdict = if self.rules.allows(&value) || !on { Verdict::Pass } else { Verdict::Mask { restore: true } };
            hits.push(Hit { start, end, kind: kind.into(), rule: det.into(), verdict, priority: 1 });
        }
        for c in &self.customs {
            for caps in c.re.captures_iter(text) {
                let m = if c.group { caps.get(1) } else { caps.get(0) };
                let Some(m) = m.filter(|m| m.end() > m.start()) else { continue };
                let value = String::from_utf8_lossy(m.as_bytes());
                let verdict = if self.rules.allows(&value) {
                    Verdict::Pass
                } else {
                    match c.action {
                        Action::Mask => Verdict::Mask { restore: true },
                        Action::MaskOnly => Verdict::Mask { restore: false },
                        Action::Block => Verdict::Block,
                    }
                };
                hits.push(Hit {
                    start: m.start(),
                    end: m.end(),
                    kind: c.kind.clone(),
                    rule: c.rule.clone(),
                    verdict,
                    priority: 0,
                });
            }
        }
        hits.retain(|h| !held.iter().any(|&(a, b)| h.start < b && a < h.end));
        hits.sort_by(|x, y| {
            x.start.cmp(&y.start).then((y.end - y.start).cmp(&(x.end - x.start))).then(x.priority.cmp(&y.priority))
        });
        // What is masked is chosen first and on its own: a find that is let
        // through (allowed, or its detector off) must never shadow a word
        // rule or another detector over the same text — `user@example.com`
        // with email off and `example.com` a word is still masked.
        let mut kept: Vec<Hit> = Vec::new();
        for h in hits.iter().filter(|h| h.verdict != Verdict::Pass) {
            if kept.last().is_some_and(|k| h.start < k.end) {
                continue;
            }
            kept.push(h.clone());
        }
        let mut passed: Vec<Hit> = Vec::new();
        for h in hits.into_iter().filter(|h| h.verdict == Verdict::Pass) {
            if kept.iter().any(|k| h.start < k.end && k.start < h.end) || passed.last().is_some_and(|p| h.start < p.end) {
                continue;
            }
            passed.push(h);
        }
        kept.extend(passed);
        kept.sort_by_key(|h| h.start);
        kept
    }

    fn token(&mut self, kind: &str, value: &str, rule: &str, masked: bool, restore: bool) -> String {
        if let Some(t) = self.by_value.get(&(kind.to_owned(), value.to_owned())) {
            let t = t.clone();
            let upgrade = masked && self.vault.entries.get(&t).is_some_and(|e| !e.masked);
            if upgrade || (masked && self.new_entries.get(&t).is_some_and(|e| !e.masked)) {
                self.new_entries.insert(t.clone(), Entry { value: value.into(), kind: kind.into(), rule: rule.into(), masked, restore, first: now() });
            }
            return t;
        }
        let vault = &self.vault;
        let fresh = &self.new_entries;
        let t = vault::token_for(&self.key, kind, value, |t| {
            vault.entries.get(t).or_else(|| fresh.get(t)).map(|e| e.value.clone())
        });
        self.new_entries.insert(t.clone(), Entry { value: value.into(), kind: kind.into(), rule: rule.into(), masked, restore, first: now() });
        self.by_value.insert((kind.into(), value.into()), t.clone());
        t
    }

    fn count(&mut self, action: &str, token: &str, kind: &str, rule: &str) {
        let e = self.tally.entry((action.into(), token.into())).or_insert((kind.into(), rule.into(), 0));
        e.2 += 1;
    }

    /// `text` with every masked find replaced, and whether a block rule
    /// matched. Inactive (off or paused), the text comes back as it is.
    pub fn mask(&mut self, text: &[u8]) -> (Vec<u8>, bool) {
        if !self.active {
            return (text.to_vec(), false);
        }
        let hits = self.find(text);
        let mut out = Vec::with_capacity(text.len());
        let mut at = 0;
        let mut blocked = false;
        for h in hits {
            let value = String::from_utf8_lossy(&text[h.start..h.end]).into_owned();
            match h.verdict {
                Verdict::Pass => {
                    let t = self.token(&h.kind, &value, &h.rule, false, false);
                    self.count("pass", &t, &h.kind, &h.rule);
                }
                Verdict::Mask { .. } | Verdict::Block => {
                    let block = h.verdict == Verdict::Block;
                    blocked |= block;
                    let restore = h.verdict == (Verdict::Mask { restore: true });
                    let t = self.token(&h.kind, &value, &h.rule, true, restore);
                    self.count(if block { "block" } else { "mask" }, &t, &h.kind, &h.rule);
                    out.extend_from_slice(&text[at..h.start]);
                    out.extend_from_slice(t.as_bytes());
                    at = h.end;
                }
            }
        }
        out.extend_from_slice(&text[at..]);
        (out, blocked)
    }

    pub fn mask_str(&mut self, text: &str) -> (String, bool) {
        let (out, blocked) = self.mask(text.as_bytes());
        (String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()), blocked)
    }

    /// Placeholders this host made, put back; any other (from another host,
    /// mask-only, or let-through) is left as written.
    pub fn restore(&mut self, text: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(text.len());
        let mut at = 0;
        let found: Vec<(usize, usize, String)> = placeholder_regex()
            .find_iter(text)
            .map(|m| (m.start(), m.end(), String::from_utf8_lossy(m.as_bytes()).into_owned()))
            .collect();
        for (a, b, token) in found {
            let entry = self.vault.entries.get(&token).or_else(|| self.new_entries.get(&token)).cloned();
            let Some(e) = entry.filter(|e| e.masked && e.restore) else { continue };
            out.extend_from_slice(&text[at..a]);
            out.extend_from_slice(e.value.as_bytes());
            at = b;
            self.count("restore", &token, &e.kind, &e.rule);
        }
        out.extend_from_slice(&text[at..]);
        out
    }

    pub fn restore_str(&mut self, text: &str) -> String {
        String::from_utf8(self.restore(text.as_bytes())).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
    }

    /// Writes the vault entries made so far, so the placeholders about to be
    /// handed out can be put back. `finish` does it too; a streaming run
    /// calls this before each piece it lets out.
    pub fn commit_vault(&mut self) -> Result<(), String> {
        if self.new_entries.is_empty() {
            return Ok(());
        }
        let entries = std::mem::take(&mut self.new_entries);
        Vault::merge(&entries)?;
        self.vault.entries.extend(entries);
        Ok(())
    }

    /// Writes what this run learned: new vault entries first, so an event
    /// never names a placeholder the vault cannot answer for. `Err` when the
    /// vault could not be written: the caller must not hand out placeholders
    /// nobody can put back.
    pub fn finish(&mut self, agent: &str, site: &str) -> Result<(), String> {
        self.commit_vault()?;
        let ts = now();
        let events: Vec<Event> = std::mem::take(&mut self.tally)
            .into_iter()
            .map(|((action, token), (kind, rule, n))| Event {
                ts,
                agent: agent.into(),
                action,
                kind,
                rule,
                token,
                n,
                site: site.into(),
            })
            .collect();
        vault::record(&events);
        Ok(())
    }
}

#[cfg(test)]
pub mod tests {
    use super::super::rules::{PatternRule, WordRule};
    use super::*;

    pub fn engine(rules: Rules) -> Engine {
        Engine::new(rules, vec![9u8; 32], Vault::default()).unwrap()
    }

    fn kinds(text: &str) -> Vec<String> {
        engine(Rules::default())
            .find(text.as_bytes())
            .into_iter()
            .filter(|h| h.verdict != Verdict::Pass)
            .map(|h| format!("{}:{}", h.rule, String::from_utf8_lossy(&text.as_bytes()[h.start..h.end])))
            .collect()
    }

    #[test]
    fn finds_what_it_should() {
        let cases: &[(&str, &str)] = &[
            ("ssh 192.0.2.10 -p 22", "ipv4_public:192.0.2.10"),
            ("gw 192.168.100.200,", "ipv4_lan:192.168.100.200"),
            ("node 10.1.2.3:8080", "ipv4_lan:10.1.2.3"),
            ("peer 172.20.0.5/16", "ipv4_lan:172.20.0.5"),
            ("ts 100.101.102.103", "ipv4_tailscale:100.101.102.103"),
            ("addr 2001:db8::1 up", "ipv6_global:2001:db8::1"),
            ("[2001:db8:0:0:1:2:3:4]:443", "ipv6_global:2001:db8:0:0:1:2:3:4"),
            ("fe80::1c2b:3aff:fe4d:5e6f%en0", "ipv6_link_local:fe80::1c2b:3aff:fe4d:5e6f"),
            ("ula fd7a:115c:a1e0::1234 x", "ipv6_ula:fd7a:115c:a1e0::1234"),
            ("ether 3c:22:fb:12:34:56 ", "mac:3c:22:fb:12:34:56"),
            ("ether 3C-22-FB-12-34-56", "mac:3C-22-FB-12-34-56"),
            ("mail someone.else+tag@example.org.", "email:someone.else+tag@example.org"),
            ("call +65 9123 4567 now", "phone:+65 9123 4567"),
            ("手机 13812345678。", "phone:13812345678"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "secrets:sk-ant-api03-abcdefghijklmnopqrstuvwxyz"),
            ("export TOKEN=abc123def456ghi789", "secrets:abc123def456ghi789"),
            ("auth tskey-auth-kAbCdEf1234567CNTRL-xyz", "secrets:tskey-auth-kAbCdEf1234567CNTRL-xyz"),
        ];
        for (text, want) in cases {
            assert_eq!(kinds(text), vec![want.to_string()], "in {text:?}");
        }
    }

    #[test]
    fn leaves_ordinary_text_alone() {
        for text in [
            "at 12:34:56 on 2026-11-15T08:00:00Z",
            "version 1.2.3.4.5 and v10.0.19041.1",
            "Chrome 120.0.6099.109",
            "std::io::Result and Vec::new() and a::b",
            "icon@2x.png and @types/node and pkg@1.2.3",
            "loopback 127.0.0.1 and ::1 and 0.0.0.0",
            "netmask 255.255.255.0",
            "ratio 16:9 and 3:2:1",
            "sha256:abcdef0123456789",
            "timestamp 1731657600000",
            "token: Option<String>",
            "git@github.com:owner/repo.git",
            "uuid 123e4567-e89b-12d3-a456-426614174000",
            "arr[1::2] and arr[::2] and a::b1",
            "+2026-11-15T08:00:00Z in a diff",
            "pi 3.14159265359",
            "version v1.2.3.4",
            "token = base64.b64encode(x)",
            "systemctl start getty@tty1.service",
        ] {
            assert_eq!(kinds(text), Vec::<String>::new(), "in {text:?}");
        }
    }

    #[test]
    fn masks_and_restores() {
        let mut e = engine(Rules::default());
        let (out, blocked) = e.mask_str("connect 192.0.2.7 as ops@example.net then 192.0.2.7");
        assert!(!blocked);
        assert!(!out.contains("192.0.2.7") && !out.contains("ops@example.net"), "{out}");
        let ip = placeholder_regex().find(out.as_bytes()).unwrap();
        let ip = String::from_utf8_lossy(ip.as_bytes()).into_owned();
        assert_eq!(out.matches(&ip).count(), 2, "one value, one placeholder: {out}");
        assert_eq!(e.restore_str(&out), "connect 192.0.2.7 as ops@example.net then 192.0.2.7");
    }

    #[test]
    fn masking_is_idempotent() {
        let mut e = engine(Rules {
            words: vec![WordRule { text: "ip".into(), ..Default::default() }],
            ..Default::default()
        });
        let (once, _) = e.mask_str("host 192.0.2.7");
        let (twice, _) = e.mask_str(&once);
        assert_eq!(once, twice, "a word rule must not match inside a placeholder");
    }

    #[test]
    fn allowlist_switches_and_pause() {
        let mut rules = Rules::default();
        rules.allow.push("192.0.2.53".into());
        rules.detect.email = false;
        let mut e = engine(rules.clone());
        let (out, _) = e.mask_str("dns 192.0.2.53 mail a@example.com");
        assert_eq!(out, "dns 192.0.2.53 mail a@example.com");
        rules.paused_until = now() + 60;
        let mut e = engine(rules);
        assert_eq!(e.mask_str("host 192.0.2.9").0, "host 192.0.2.9");
    }

    #[test]
    fn word_and_pattern_rules() {
        let rules = Rules {
            words: vec![
                WordRule { text: "Studio-Mac".into(), ..Default::default() },
                WordRule { text: "codename".into(), action: Action::MaskOnly, ..Default::default() },
                WordRule { text: "forbidden".into(), action: Action::Block, ..Default::default() },
            ],
            patterns: vec![
                PatternRule { name: "ticket".into(), pattern: r"ACME-(\d{4})".into(), kind: "Ticket".into(), ..Default::default() },
                PatternRule { name: "bad".into(), pattern: r"(unclosed".into(), ..Default::default() },
            ],
            ..Default::default()
        };
        let mut e = engine(rules);
        assert_eq!(e.errors.len(), 1);
        let (out, blocked) = e.mask_str("on studio-mac, CODENAME, ACME-1234");
        assert!(!blocked);
        assert!(out.starts_with("on ⟦word:"), "{out}");
        assert!(out.contains("ACME-⟦ticket:"), "{out}");
        let back = e.restore_str(&out);
        assert!(back.contains("studio-mac") && back.contains("ACME-1234"), "{back}");
        assert!(!back.contains("CODENAME"), "mask-only stays masked: {back}");
        assert!(e.mask_str("a forbidden word").1);
    }

    #[test]
    fn a_find_let_through_never_shadows_one_masked() {
        let mut rules = Rules::default();
        rules.detect.email = false;
        rules.words.push(WordRule { text: "example.com".into(), ..Default::default() });
        let (out, _) = engine(rules).mask_str("mail user@example.com");
        assert!(!out.contains("example.com"), "{out}");
    }

    #[test]
    fn foreign_placeholders_are_left_alone() {
        let mut e = engine(Rules::default());
        assert_eq!(e.restore_str("x ⟦ip:abcdef⟧ y"), "x ⟦ip:abcdef⟧ y");
    }
}
