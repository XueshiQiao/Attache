# attache-cli

The host side of Attaché. The phone, and later the desktop app, read agents
through it: one binary, installed by whichever client connects first (never
downgraded), so neither client depends on the other having set anything up.

It reads only what the agents write for themselves: Claude Code's session
files and transcripts, Antigravity's (`agy`) transcripts, presence locks and
screen. Nothing else on the host has to be installed or running.

## Commands

Each runs as its own short process, except `follow` and `agents --watch`,
which run until the client that started them goes.

| Command | Called by | Does |
|---|---|---|
| `version` | clients | `{"version","protocol","os","arch"}` |
| `setup` / `uninstall` | clients | puts `statusline` into Claude Code's `statusLine` (keeping the old one, which it runs), or takes it out |
| `agents [--pane %N]` | clients | every agent in tmux, one JSON object a line |
| `agents --watch [--pane %N]` | clients | the same, pushed whenever it changes; with `--pane`, that pane's `screen` too |
| `screen <%pane>` | clients | what Claude has on screen that a client may act on: its input box, a permission menu, a panel, the working line |
| `seen <kind> <conversation>` | clients | the person looked at it: Done becomes Idle |
| `follow <claude\|agy> <transcript> [--before <offset>]` | clients | a conversation as rows, then every change |
| `input <%pane> --text <base64> [--enter]` / `--key <name> --if <condition>` | clients | types into an agent, one message at a time per pane, only after reading the screen again itself |
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

`agents --watch`: `{"t":"agents","agents":[…]}` (the rows above) and, with
`--pane`, `{"t":"screen",…}` (what `screen` prints), each sent at once and
then whenever it changed.

`screen`: `pane`, `kind`, `prompt` (Claude's input box is showing),
`approval` (`subject`, `question`, `options` of `number`, `label`, `risk`,
and `fingerprint`, a hash of the whole dialog, the command included),
`panel` (its last rows) and `panel_fingerprint`, `question` (an
`AskUserQuestion` with one question and one answer: `header`, `question`,
`options` of `number`, `label`, `description`, `typed`, plus `cursor` and
`fingerprint`, which leaves the cursor out), `activity` (`verb`, `detail`).
Only Claude's screen is read; on another agent all of them are empty.

`input` prints `{"sent":true}` or `{"sent":false,"why":…}`. **No key and no
message is sent on the strength of what a client was shown**: a key
names the screen it is for, `--if approval:<fingerprint>` (a digit, that
very menu), `--if panel` (arrows, Tab, Esc) or `--if panel:<fingerprint>`
(those and Enter, which chooses, on that very panel), or `--if working`
(Esc, while the working line is up and Claude's session file says busy).
`--choose <n> --if question:<fingerprint>` answers a question: the cursor
is moved to answer `n` with arrows, the screen read again, and Enter
pressed only if the cursor arrived on that very question; answers that
need typing are refused (`typed_answer`).
A message needs an agent in the pane and, for Claude, its input box with
no menu or panel over it, checked again before its Enter. All of it is read
holding the pane, just before anything is pressed, after leaving copy mode
(a key sent into copy mode is a copy-mode key). A key in the wrong place can cost a session its
prompt cache: an Esc on the idle prompt is half of the two that open the
rewind menu, a Tab there turns thinking on or off, and a message typed into
a picker ends with an Enter that chooses something. `why` is `question`,
`panel`, `no_prompt`, `no_agent`, `enter_withheld` (the text went in, its
Enter did not), `question_gone`, `question_changed`, `no_such_option`,
`panel_closed`, `panel_changed`, `not_working`, `not_claude`, `busy` or
`tmux`.

Protocol 2 (attache-cli 0.2.0) removed `--key` without `--if`.

`follow`:

```text
{"t":"waiting"}                        the file does not exist yet
{"t":"hello","protocol":2,"kind":…,"path":…,"start":<offset>,"earlier":<bool>}
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
