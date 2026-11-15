//! `guard run`: the one way a command an agent wrote gets real values.
//!
//! The agent's command arrives holding placeholders. This process puts the
//! real values back in its own memory, runs the command, and masks what the
//! command prints before the agent's tool reads a byte of it — so the value
//! is in neither the command the agent's transcript records nor the output.
//! That is what makes it the whole answer for Codex and agy, whose hooks
//! can rewrite a command but not its output.
//!
//! Output is masked as it streams, a line at a time. A value can be cut
//! between two reads, so an unfinished line is held until its newline; when
//! the command goes quiet with a line still open (a prompt waiting for an
//! answer), the line is let out — all but its last run of characters that
//! could still be the start of an address, which waits a little longer.

use super::detect::Engine;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Exit status when the guard refused to run the command at all.
pub const REFUSED: i32 = 125;

const QUIET: Duration = Duration::from_millis(150);
/// How long a possibly-cut tail may wait before it goes out anyway.
const TAIL_WAIT: Duration = Duration::from_millis(1200);
/// A line longer than this is let out in pieces.
const LINE_MAX: usize = 64 << 10;
/// A private key block is held whole until its END line, up to this much.
const KEY_MAX: usize = 32 << 10;

/// A byte that could be the middle of a value still being written: an
/// address, an email, a key (base64 too), or any non-ASCII byte — a word
/// rule may be Chinese, and a UTF-8 character can itself be cut.
fn could_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b >= 0x80 || matches!(b, b'.' | b':' | b'@' | b'_' | b'+' | b'-' | b'%' | b'/' | b'=')
}

/// How many bytes at the end of `buf` could still be the start of a value:
/// a run of `could_continue` bytes, taken across a space that follows a
/// digit, because a phone number is written in groups (`+65 9123 45`).
fn open_tail(buf: &[u8]) -> usize {
    let mut n = 0;
    while n < buf.len() {
        let b = buf[buf.len() - 1 - n];
        let before = buf.len().checked_sub(n + 2).map(|i| buf[i]);
        if could_continue(b) || (b == b' ' && before.is_some_and(|p| p.is_ascii_digit() || p == b'+')) {
            n += 1;
        } else {
            break;
        }
    }
    n
}

/// Where a private key block that is not finished yet starts, if one does:
/// the last `-----BEGIN ` whose header names a private key (or is not
/// whole yet), with no `-----END …KEY-----` after it.
fn open_key(buf: &[u8]) -> Option<usize> {
    let begin = rfind(buf, b"-----BEGIN ")?;
    let rest = &buf[begin..];
    let header = rest.split(|&b| b == b'\n').next().unwrap_or(rest);
    let header_done = rest.len() > header.len();
    if header_done && find(header, b"PRIVATE KEY").is_none() {
        return None;
    }
    let finished = find(rest, b"-----END ").is_some_and(|e| find(&rest[e..], b"KEY-----").is_some());
    (!finished && rest.len() < KEY_MAX).then_some(begin)
}

/// Splits `buf` into what can be masked and let out now, and what must wait.
fn ready(buf: &[u8], quiet_for: Option<Duration>) -> usize {
    if let Some(begin) = open_key(buf) {
        // Everything before the block's line can go; the block waits for END.
        return buf[..begin].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    }
    let lines = buf.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    if lines == buf.len() {
        return lines;
    }
    let open = buf.len() - lines;
    let tail = open_tail(buf);
    match quiet_for {
        Some(q) if q >= TAIL_WAIT => buf.len(),
        Some(_) => buf.len() - tail.min(open),
        None if open > LINE_MAX => buf.len() - tail.min(4096),
        None => lines,
    }
}

fn rfind(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).rposition(|w| w == needle)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn pump(mut from: impl Read + Send + 'static, mut to: impl Write, engine: Arc<Mutex<Engine>>) {
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        let mut chunk = vec![0u8; 16 << 10];
        loop {
            match from.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(chunk[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let mut buf: Vec<u8> = Vec::new();
    let mut last = Instant::now();
    let emit = |buf: &mut Vec<u8>, n: usize, to: &mut dyn Write| {
        if n == 0 {
            return;
        }
        let part: Vec<u8> = buf.drain(..n).collect();
        // The vault is written before the placeholders go out: one the
        // agent holds must be one this host can put back. Anything that
        // goes wrong withholds the text rather than lets it through.
        let out = match engine.lock() {
            Ok(mut e) => {
                let (out, blocked) = e.mask(&part);
                match e.commit_vault() {
                    Err(why) => format!("[Attaché privacy guard withheld this output: {why}]\n").into_bytes(),
                    Ok(()) if blocked => "[Attaché privacy guard withheld this output: it matched a block rule]\n".as_bytes().to_vec(),
                    Ok(()) => out,
                }
            }
            Err(_) => "[Attaché privacy guard withheld this output]\n".as_bytes().to_vec(),
        };
        let _ = to.write_all(&out);
        let _ = to.flush();
    };
    loop {
        match rx.recv_timeout(QUIET) {
            Ok(data) => {
                buf.extend_from_slice(&data);
                last = Instant::now();
                let n = ready(&buf, None);
                emit(&mut buf, n, &mut to);
            }
            Err(RecvTimeoutError::Timeout) => {
                if !buf.is_empty() {
                    let n = ready(&buf, Some(last.elapsed()));
                    emit(&mut buf, n, &mut to);
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let n = buf.len();
    emit(&mut buf, n, &mut to);
}

pub fn run(engine: Engine, command: RunCommand, agent: &str) -> i32 {
    let engine = Arc::new(Mutex::new(engine));
    let mut cmd = {
        let mut e = engine.lock().expect("fresh lock");
        match command {
            RunCommand::Shell(text) => {
                let shell = std::env::var("SHELL").ok().filter(|s| s.starts_with('/')).unwrap_or_else(|| "/bin/sh".into());
                let mut c = Command::new(shell);
                c.arg("-c").arg(e.restore_str(&text));
                c
            }
            RunCommand::Argv(argv) => {
                let argv: Vec<String> = argv.iter().map(|a| e.restore_str(a)).collect();
                let mut c = Command::new(&argv[0]);
                c.args(&argv[1..]);
                c
            }
        }
    };
    cmd.stdin(Stdio::inherit()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("attache-cli guard run: {e}");
            return 127;
        }
    };
    let out = child.stdout.take().expect("piped");
    let err = child.stderr.take().expect("piped");
    let (e1, e2) = (engine.clone(), engine.clone());
    let t1 = thread::spawn(move || pump(out, std::io::stdout(), e1));
    let t2 = thread::spawn(move || pump(err, std::io::stderr(), e2));
    let status = child.wait();
    let _ = t1.join();
    let _ = t2.join();
    if let Ok(mut e) = engine.lock() {
        let _ = e.finish(agent, "run");
    }
    match status {
        Ok(s) => {
            use std::os::unix::process::ExitStatusExt;
            s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(1))
        }
        Err(_) => 1,
    }
}

pub enum RunCommand {
    Shell(String),
    Argv(Vec<String>),
}

#[cfg(test)]
mod tests {
    use super::super::detect::tests::engine;
    use super::super::rules::Rules;
    use super::*;

    /// Feeds `input` cut at every byte boundary, the way a pipe may deliver
    /// it, and checks no value ever leaves unmasked in any cut.
    #[test]
    fn values_cut_between_reads_stay_masked() {
        let input = b"first 192.0.2.77 line\nmail ops@example.net\npartial 198.51.100.4";
        for cut in 1..input.len() {
            let mut buf: Vec<u8> = Vec::new();
            let mut out: Vec<u8> = Vec::new();
            let mut e = engine(Rules::default());
            for piece in [&input[..cut], &input[cut..]] {
                buf.extend_from_slice(piece);
                // A quiet moment after each read, shorter than TAIL_WAIT.
                for quiet in [None, Some(QUIET)] {
                    let n = ready(&buf, quiet);
                    let part: Vec<u8> = buf.drain(..n).collect();
                    out.extend(e.mask(&part).0);
                }
            }
            out.extend(e.mask(&buf).0);
            let text = String::from_utf8_lossy(&out);
            for v in ["192.0.2.77", "ops@example.net", "198.51.100.4", "192.0.2.", "198.51.100"] {
                assert!(!text.contains(v), "cut at {cut}: {text}");
            }
        }
    }

    #[test]
    fn a_waiting_prompt_is_let_out() {
        assert_eq!(ready(b"Password: ", Some(QUIET)), 10);
        assert_eq!(ready(b"Continue? [y/N]", Some(QUIET)), 15);
        // A tail that could still grow into an address waits a little.
        assert_eq!(ready(b"connecting to 192.0.2", Some(QUIET)), "connecting to ".len());
        assert_eq!(ready(b"connecting to 192.0.2", Some(TAIL_WAIT)), 21);
    }

    #[test]
    fn tails_that_could_still_grow_wait() {
        assert_eq!(open_tail(b"call +65 9123 45"), "+65 9123 45".len());
        assert_eq!(open_tail(b"key: abc/def="), "abc/def=".len());
        assert_eq!(open_tail("主机 名字".as_bytes()), "名字".len());
        assert_eq!(open_tail(b"Password: "), 0);
    }

    #[test]
    fn a_key_block_cut_anywhere_is_held() {
        let block = b"x\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAsecretBBBB\n-----END OPENSSH PRIVATE KEY-----\n";
        for cut in 3..block.len() - 1 {
            let n = ready(&block[..cut], None);
            assert!(n <= 2, "cut at {cut}: let out {n} bytes");
        }
        let two = b"-----BEGIN RSA PRIVATE KEY-----\nA\n-----END RSA PRIVATE KEY-----\n-----BEGIN EC PRIVATE KEY-----\nB\n";
        let n = ready(two, None);
        assert!(!String::from_utf8_lossy(&two[..n]).contains("EC PRIVATE"), "the second, open key waits");
        let cert = b"-----BEGIN CERTIFICATE-----\nMIIB\n";
        assert_eq!(ready(cert, None), cert.len(), "a certificate is not held");
    }

    #[test]
    fn a_private_key_is_held_until_its_end() {
        let begin = b"ok\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n";
        assert_eq!(ready(begin, None), 3);
        let mut whole = begin.to_vec();
        whole.extend_from_slice(b"-----END OPENSSH PRIVATE KEY-----\n");
        assert_eq!(ready(&whole, None), whole.len());
        let (out, _) = engine(Rules::default()).mask(&whole);
        assert!(!String::from_utf8_lossy(&out).contains("AAAA"));
    }
}
