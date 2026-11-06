//! attache-cli: the host side of Attaché.
//!
//! One binary, one subcommand per job, each run as its own short process by
//! whoever needs it (see `fsutil` for how they share state without talking
//! to each other). Called as `attache-send`, it is `send`, so the name the
//! agents' instructions already use keeps working.

mod agents;
mod agy_transcript;
mod chat;
mod claude_transcript;
mod follow;
mod fsutil;
mod host;
mod input;
mod paths;
mod send;
mod setup;
mod statusline;
mod time;
mod tmux;

use serde_json::json;

/// The version of what other programs read from this one: the output of
/// every subcommand and the files under the state folder. Fields are only
/// ever added within one protocol; anything else raises it, and a client
/// that does not know the new number says so instead of misreading.
pub const PROTOCOL: u32 = 1;

fn main() {
    let mut args: Vec<String> = std::env::args().collect();
    let invoked = args
        .first()
        .map(|a| a.rsplit('/').next().unwrap_or(a).to_owned())
        .unwrap_or_default();
    let rest: Vec<String> = args.split_off(1.min(args.len()));
    let code = if invoked == "attache-send" {
        send::run(&rest)
    } else {
        dispatch(&rest)
    };
    std::process::exit(code);
}

fn dispatch(args: &[String]) -> i32 {
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.as_str(), r),
        None => ("help", &[][..]),
    };
    match cmd {
        "version" | "--version" => {
            println!(
                "{}",
                json!({
                    "version": env!("CARGO_PKG_VERSION"),
                    "protocol": PROTOCOL,
                    "os": std::env::consts::OS,
                    "arch": std::env::consts::ARCH,
                })
            );
            0
        }
        "send" => send::run(rest),
        "agents" => agents::run(rest, &host::RealHost),
        "seen" => agents::run_seen(rest),
        "follow" => follow::run(rest),
        "input" => input::run(rest),
        "statusline" => statusline::run(rest),
        "setup" => setup::run_setup(),
        "uninstall" => setup::run_uninstall(),
        _ => {
            eprintln!(
                "attache-cli {}\n\nUsage:\n  attache-cli version\n  attache-cli send <file>...\n  attache-cli agents [--pane %N]\n  attache-cli seen <kind> <conversation>\n  attache-cli follow <claude|agy> <transcript> [--before <offset>]\n  attache-cli input <%pane> --text <base64> [--enter] | --key <name>\n  attache-cli setup | uninstall\n  attache-cli statusline claude   (run by Claude Code)",
                env!("CARGO_PKG_VERSION")
            );
            if cmd == "help" || cmd == "--help" {
                0
            } else {
                2
            }
        }
    }
}
