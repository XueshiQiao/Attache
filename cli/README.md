# attache-cli

The host side of Attaché. The phone, and later the desktop app, read agents
through it: one binary, installed by whichever client connects first (never
downgraded), so neither client depends on the other having set anything up.

It reads only what the agents write for themselves: Claude Code's session
files and transcripts, Antigravity's (`agy`) transcripts, presence locks and
screen. Nothing else on the host has to be installed or running.

## Commands

Each runs as its own short process, except `follow`, `agents --watch` and
`usage --watch`, which run until the client that started them goes.

| Command | Called by | Does |
|---|---|---|
| `version` | clients | `{"version","protocol","os","arch"}` |
| `setup` / `uninstall` | clients | puts `statusline` into Claude Code's `statusLine` (keeping the old one, which it runs), or takes it out |
| `agents [--pane %N]` | clients | every agent in tmux, one JSON object a line |
| `agents --watch [--pane %N]` | clients | the same, pushed whenever it changes; with `--pane`, that pane's `screen` too |
| `screen <%pane>` | clients | what Claude has on screen that a client may act on: its input box, a permission menu, a panel, the working line |
| `seen <kind> <conversation>` | clients | the person looked at it: Done becomes Idle |
| `rename <%pane> --name <base64>` | clients | makes the name the pane's title, which the program in it can then no longer change; an empty name gives the title back |
| `follow <claude\|agy> <transcript> [--before <offset>]` | clients | a conversation as rows, then every change |
| `input <%pane> --text <base64> [--enter]` / `--key <name> --if <condition>` | clients | types into an agent, one message at a time per pane, only after reading the screen again itself |
| `usage` | clients | the AI subscriptions' usage (Claude, Antigravity, Grok), refreshed by the desktop app on request |
| `usage --watch` | clients | the same, pushed whenever it changes; asks the desktop app every 5 minutes |
| `projects` | clients | the saved projects, one JSON object a line |
| `project save [--id <id>] --name <base64> --path <base64> --command <base64>` | clients | keeps a project (a folder and the command to start in it); with `--id`, changes that one |
| `project remove <id>` | clients | forgets it |
| `project open <id> --session <$N>` | clients | a new window in that session, in the folder, running the command in the person's own shell |
| `project draft <@window>` | clients | what saving that window would start from: its name, its folder, how its agent was started |
| `project commands [--set <base64>]` | clients | the person's often-used commands, offered when a project is saved; `--set` replaces the list (one command a line) |
| `tags` | clients | the window tags there are, and the colours a tag may have |
| `tag save [--id <id>] --name <base64> --color <colour>` | clients | keeps a tag (a name and a colour); with `--id`, changes that one |
| `tag remove <id>` | clients | forgets it and takes it off every window that carries it |
| `mermaid --source <base64> [--dark] [--scale <1-4>] [--inline]` | clients | draws a Mermaid diagram as a PNG, for a ```` ```mermaid ```` block in a reply |
| `guard status` | clients | the privacy guard on this host: on, paused, and whether each agent (Claude Code, Codex, agy) is wired up, with what that does and does not cover |
| `guard rules [--set <base64 json>]` | clients | the guard's rules as JSON (`{"rules","errors","path"}`); `--set` replaces them and answers `{"saved":…}` |
| `guard test --text <base64> [--rules <base64 json>]` | clients | what the rules (saved, or the ones given) would find in a text: byte offsets, rule, verdict, and the masked text; records nothing |
| `guard events [--limit N] [--clear]` | clients | what was masked, restored, withheld or let through, newest last; placeholders only, never a value |
| `guard vault [--forget <placeholder>… \| --forget-all]` | clients | the placeholders this host made (without their values), or forgets some |
| `guard reveal <placeholder>…` | clients | the values, for the owner's own screen; refused when an agent's environment is set |
| `guard install \| uninstall <claude\|codex\|agy>` | clients | wires the guard into that agent, or takes it out (see below) |
| `guard pause <minutes>` | clients | stands the guard aside for a while; `0` resumes |
| `guard mask [--json]` / `guard restore [--json \| --sh <text>]` | the Claude Code mod | swaps values for placeholders, or back |
| `guard run --agent <a> [--rules-snapshot <sha256>] --sh <command>` | Codex and agy hooks | puts the values back in its own memory, runs the command, masks its output as it streams; with `--rules-snapshot`, reads the copy of the rules the hook left in the state folder instead of `~/.config` |
| `guard hook <name>` | agents' hooks | one JSON event in, the agent's answer out (`claude-pre`, `claude-post`, `codex-pre`, `codex-post`, `codex-prompt`, `agy-pre`) |
| `statusline claude` | Claude Code | keeps the status line snapshot, draws the old status line |
| `send <file>...` (also as `attache-send`) | people, agents | hands files to the phone's inbox |

## What other programs read

Every output is JSON lines. `protocol` (in `version` and in `follow`'s
`hello`) only changes when something is removed or changes meaning; fields
are only ever added within one protocol.

`agents`: `pane`, `pid`, `session`, `window`, `window_index`, `window_name`,
`command`, `path`, `title`, `kind` (`claude`, `agy`, `codex`, `grok`,
`gemini`), `state` (`working`, `needs_you`, `done`, `idle`, `unknown`),
`since`, `conversation`, `transcript`, `cwd`, `model`, `name` (the pane's
title when the person renamed it with `rename`, else null).

`agents --watch`: `{"t":"agents","agents":[…]}` (the rows above) and, with
`--pane`, `{"t":"screen",…}` (what `screen` prints), each sent at once and
then whenever it changed.

`usage` and `usage --watch`: `{"t":"usage_desktop","state","why"}`
(`state` is `ok`, `not_running` when the desktop app is not listening,
`failed` with `why`, or `unsupported` off macOS), and one
`{"t":"usage","provider",…}` per provider whose file holds an answer or a
failure; under `--watch` each is sent again when it changes, in no fixed
order between the two kinds. A `usage` line has `plan`, `source`,
`fetched_at`, `stored_at` and `windows` of `id`, `title`, `group`, `kind`
(`session`, `weekly`, `other`), `used_percent`, `resets_at`,
`window_seconds`, all present only once an ask has succeeded; `error`
(`failed`, `timeout`, `busy`) and `failed_at` when the last ask failed,
beside the last good numbers if there are any. Times are epoch seconds.

`projects`: `id`, `name`, `path` (as written: `~/…` is the home folder
of whoever runs it), `command` (empty for a plain shell), `exists` (the
folder is there now). `project save` answers the same object with
`"saved":true`, or `{"saved":false,"why"}`; `remove` answers
`{"removed":true,"id"}`, `open` `{"opened":true,"id","window","pane"}`,
`draft` `{"draft":true,"name","path","command"}`, each with `false` and a
`why` when it did not happen. Opening one twice makes two windows.
`projects` ends with `{"commands":[…]}`, which is also what `project
commands` prints: the commands a client offers in its save form. Opening
never consults it; a project runs the command in its own block. Until the
person has written a list, it is the commands their saved projects run.
That line is always the last, so an answer without it was cut short; it
carries `commands_why` when the list in the file cannot be edited from a
client (written over several lines).

`tags`: one line, `{"tags":[{"id","name","color"},…],"colors":[…]}`, the
tags in the file's order and the colour names (`gray`, `red`, `orange`,
`yellow`, `green`, `teal`, `blue`, `purple`, `pink`; a colour written in
the file that is not one of them reads as `gray`). `tag save` answers the
tag with `"saved":true`, or `{"saved":false,"why"}` — a name another tag
already has (letter case aside) is refused. `tag remove` answers
`{"removed":true,"id","windows"}`, `windows` being how many windows it
was taken off. Which window carries which tag is not kept here: it is the
window's tmux option `@attache_tags`, tag ids separated by commas, which a
client sets itself (`set-option -w -t @N @attache_tags <ids>`, `-wu` for
none) and reads with `#{@attache_tags}`; it goes when the window goes.
Every save and remove also sets the global option `@attache_tags_rev` on
the default tmux server to a new value, so a client subscribed to it
(`refresh-client -B 'name::#{@attache_tags_rev}'`) reads the list again
instead of asking on a timer. A client that changes a window's tags sets
the global `@attache_window_tags_rev` the same way, for clients that cannot
subscribe to every window: a `@*` subscription covers only the windows of
the session a control client sits in, while a global option's fires from
any session.

Nothing in it is worked out or asked here. AIUsageKit
(github.com/XueshiQiao/AIUsageKit) asks each provider's own CLI and keeps
the answers in `~/Library/Caches/AIUsageKit/v1/`; the desktop app does the
asking, on request: `usage` calls the app's `usage.refresh` over the Unix
socket `~/.local/state/attache/desktop.sock` (one line of JSON each way)
and passes the files on. It cannot ask itself, because Claude keeps its
login in the macOS login keychain and a process that came in over SSH
cannot read it (XueshiQiao/Attache#39). Usage is the one thing the phone
may depend on the desktop app for; its core never does.

`screen`: `pane`, `kind`, `prompt` (Claude's input box is showing),
`approval` (`subject`, `question`, `options` of `number`, `label`, `risk`,
and `fingerprint`, a hash of the whole dialog, the command included),
`panel` (its last rows) and `panel_fingerprint`, `question` (an
`AskUserQuestion`: `header`, `question`, `tabs` of `title`, `answered` when
several are asked, `multi`, `review` with `answers` of `question`, `answer`
on the last tab, `options` of `number`, `label`, `description`, `typed`,
`checked`, plus `cursor` (an option's number, 0 for Submit), `submit_row`,
and `fingerprint`, which leaves the cursor and the hint line out), `activity` (`verb`, `detail`).
Only Claude's screen is read; on another agent all of them are empty.

`rename` sets the pane's `allow-set-title` off, marks it `@attache_renamed`
and sets its title, every `#` doubled because `select-pane -T` expands
formats and `#(…)` in a format runs a command; a reset unsets both and puts
back Claude's own title (its transcript's last `ai-title`) or an empty
one. It prints `{"renamed":true,"pane","name"}` or
`{"renamed":false,"why"}`.

`input` prints `{"sent":true}` or `{"sent":false,"why":…}`. **No key and no
message is sent on the strength of what a client was shown**: a key
names the screen it is for, `--if approval:<fingerprint>` (a digit, that
very menu), `--if panel` (arrows, Tab, Esc) or `--if panel:<fingerprint>`
(those and Enter, which chooses, on that very panel), or `--if working`
(Esc, while the working line is up and Claude's session file says busy).
`--choose <n|submit> --if question:<fingerprint>` answers a question (or,
in a multiple choice, ticks answer `n`; `submit` is its Submit row): the
cursor is moved there with arrows, the screen read again, and Enter
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

Rows: `user` (`text`, `queued`), `agent` (`text`), `narration` (`text`),
`thinking` (`text`), `tool` (`name`, `summary`, `detail`, `result`,
`error`, `diff` as `[kind, text]` pairs), `output` (`text`, `error`, `raw`),
`note` (`text`); each has a `key` that stays the same across rereads.
`narration` (0.3.17) is a line the agent wrote to the person along the way
that Claude Code files as a thinking block; a client shows it like `agent`,
not folded with the work. Claude Code keeps its real thinking empty, so a
Claude conversation has no `thinking` rows; agy's do.

`mermaid`: one line, `{"mermaid":true,"width","height","scale","path"}`
or `{"mermaid":false,"why"}`. `path` is a PNG under this program's state
folder (`mermaid/`, kept a week), for a client that fetches files from the
host; with `--inline` the line carries `"png"` (base64) in its place and
nothing is written. `width` and `height` are in points, and the PNG is
`scale` times that in pixels (2 unless asked), on a transparent ground.
A refusal is about the source — it cannot be drawn, now or later — so a
client keeps it and leaves the block as code; no line at all (ssh dropped,
an attache-cli from before 0.3.15) says nothing about the source and is
asked again. The text is drawn with one font of the host's own: PingFang, else
Hiragino Sans GB, STHeiti or Noto Sans CJK, else a Latin font
(`src/mermaid.rs`); a host with none of them is refused. Pixels
and not SVG because merman's SVG needs CSS applied to draw, and neither
client may use a web view for it.

## Files

Under `~/.local/state/attache/` (`$XDG_STATE_HOME/attache`):
`claude/<session>/status.json` (status line snapshot),
`<kind>/<conversation>/seen.json`, `claude/context-windows.json`,
`claude/statusline.json` (the status line `setup` replaced), and lock files.
`send` keeps `~/.local/share/attache/outbox.queue`, where `attache-send`
kept it. `usage` reads, never writes, AIUsageKit's
`~/Library/Caches/AIUsageKit/v1/`, and logs to `usage/usage.log` under the
state folder: every watch's start and end with where it came from, and
every call to the desktop app with each provider's answer, errors word for
word. The app logs its side of each call to
`~/Library/Logs/Attache/desktop-calls.log`.

Projects are the person's own and live with their settings, not here:
`~/.config/attache-projects.toml`, one `[[project]]` block each (`id`,
`name`, `path`, `command`), and above them `commands = ["cyolo", …]`. A
file from 0.3.9/0.3.10, `attache-workspaces.toml` with `[[workspace]]`
blocks, is read as it is and moved to the new name by the first change
(beside its target, behind a new link, when it was a link into a dotfiles
folder; left alone when a new file is already there). It is theirs to edit by hand: this program
rewrites only the values of those four keys in the block it is changing,
writes through a link to the file it points at, and a block written
without an `id` works as it is.

Window tags too: `~/.config/attache-tags.toml`, one `[[tag]]` block each
(`id`, `name`, `color`), rewritten the same way — only those three keys'
values in the block being changed, through a link to the file it points
at. A block written without an `id` works under one worked out from its
name.

The privacy guard's rules are the person's too:
`~/.config/attache-guard.toml` (`enabled`, `paused_until`, `allow = [...]`,
`[detect]` switches, `[[word]]` and `[[pattern]]` blocks), read on every
run, so an edit applies to the next row an agent stores. Saving from a
client rewrites the whole file. The real values live only under
`guard/` in the state folder, mode 0700: `key` (this host's HMAC key; a
placeholder is `⟦<kind>:<6+ hex>⟧` of the value), `vault.json`
(placeholder → value) and `events.jsonl` (placeholders only), all 0600.
Not the Keychain: its access list names the binary, which every upgrade
replaces, so each upgrade would raise a dialog in front of whichever agent
ran first — on a host over SSH, one nobody can answer.

How each agent is wired, measured 2026-11-15 on Claude Code 2.1.325, Codex
0.164 and agy 1.5.9: Claude Code gets a mod (`guard-mod/`, embedded in this
binary, written to `~/.local/share/attache/claude-guard/` and named in
`env.CLAUDE_CODE_PLUGIN_DIRS` of `~/.claude/settings.json`) that masks the
prompt, every stored row and every tool result (whose structured record a
row hook cannot reach — it kept a raw value in the first experiment), and
puts real values back into tool arguments; the transcript then holds
placeholders only. Codex and agy can rewrite a command but not its output
(Codex answers only with a block; agy parses `overwriteResult` and ignores
it), so their commands are wrapped in `guard run`. Codex accepts a rewrite
only with `permissionDecision: allow`, but runs its own approval on the
rewritten command afterwards; commands are wrapped where Codex asks no
approval, or where one carries a placeholder. Codex's own session file
keeps output that was not wrapped; agy's prompts have no hook at all.

agy started with `--sandbox` runs each command under a macOS sandbox
profile that denies every read under `~/.config` but a fixed few agy names
itself (`~/.config/bat`, measured on agy 1.5.14, 2026-11-23), while its hooks
run outside it. So `guard run` inside could not read the rules and refused
every command. The agy hook now writes the rules it read to
`<state>/guard/rules-<sha256>.json` (0600, beside the vault, which the
sandbox can read) and names the digest in the wrapper; `guard run` refuses a
copy that is missing or no longer hashes to that name, since the sandbox
lets the model's commands write the home folder. Only the digest is in the
command the model sees, never the rules' words. The eight most recently
used copies are kept. A command is left unwrapped only when it is exactly
the wrapper the hook would write — the wrapper, then one quoted word, and
nothing after it; anything else (a command chained after a wrapper, a
wrapper naming another copy) is wrapped again, for Codex too.

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
