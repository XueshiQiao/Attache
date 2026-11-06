# attache-cli

The host side of Attaché. The phone, and later the desktop app, read agents
through it: one binary, installed by whichever client connects first (never
downgraded), so neither client depends on the other having set anything up.

It reads only what the agents write for themselves: Claude Code's session
files and transcripts, Antigravity's (`agy`) transcripts, presence locks and
screen. Nothing else on the host has to be installed or running.

## Commands

Each runs as its own short process, except `follow`, which runs until the
client that started it goes.

| Command | Called by | Does |
|---|---|---|
| `version` | clients | `{"version","protocol","os","arch"}` |
| `setup` / `uninstall` | clients | puts `statusline` into Claude Code's `statusLine` (keeping the old one, which it runs), or takes it out |
| `agents [--pane %N]` | clients | every agent in tmux, one JSON object a line |
| `seen <kind> <conversation>` | clients | the person looked at it: Done becomes Idle |
| `follow <claude\|agy> <transcript> [--before <offset>]` | clients | a conversation as rows, then every change |
| `input <%pane> --text <base64> [--enter]` / `--key <name>` | clients | types into an agent, one message at a time per pane |
| `statusline claude` | Claude Code | keeps the status line snapshot, draws the old status line |
| `send <file>...` (also as `attache-send`) | people, agents | hands files to the phone's inbox |

## What other programs read

Every output is JSON lines. `protocol` (in `version` and in `follow`'s
`hello`) only changes when something is removed or changes meaning; fields
are only ever added within one protocol.

`agents`: `pane`, `pid`, `session`, `window`, `window_index`, `window_name`,
`command`, `path`, `title`, `kind` (`claude`, `agy`, `codex`, `grok`,
`gemini`), `state` (`working`, `needs_you`, `done`, `idle`, `unknown`),
`since`, `conversation`, `transcript`, `cwd`, `model`.

`follow`:

```text
{"t":"waiting"}                        the file does not exist yet
{"t":"hello","protocol":1,"kind":…,"path":…,"start":<offset>,"earlier":<bool>}
{"t":"items","from":<n>,"items":[…]}   rows n.. replaced by these
{"t":"status",…}                       what the header shows, when it changed
{"t":"switched","path":…}              the conversation moved to another file
```

Rows: `user` (`text`, `queued`), `agent` (`text`), `thinking` (`text`),
`tool` (`name`, `summary`, `detail`, `result`, `error`, `diff` as
`[kind, text]` pairs), `output` (`text`, `error`, `raw`), `note` (`text`);
each has a `key` that stays the same across rereads.

## Files

Under `~/.local/state/attache/` (`$XDG_STATE_HOME/attache`):
`claude/<session>/status.json` (status line snapshot),
`<kind>/<conversation>/seen.json`, `claude/context-windows.json`,
`claude/statusline.json` (the status line `setup` replaced), and lock files.
`send` keeps `~/.local/share/attache/outbox.queue`, where `attache-send`
kept it.

Processes never talk to each other, only through these files: each is
replaced by rename, never edited in place, and every read-modify-write takes
a `flock`.

## Building and testing

```sh
./build-all.sh   # dist/{darwin-arm64,darwin-x86_64,linux-aarch64,linux-x86_64}/attache-cli
cargo test
```

The tests that need tmux start their own server with `-L` on every command
and never touch the owner's. `ATTACHE_TMUX` (another tmux binary) and
`ATTACHE_TMUX_SOCKET` (`-L <name>`) are how they point this program at it:
tmux finds its server by user id, not by `HOME`.
