# Sidebar status: Git state and agent state on the window rows

Design note, 2026-07-28. Covers two features and one defect:

1. Window rows in the rail become two lines, the second carrying Git state.
2. The rail shows what a coding agent in that window is doing — Claude Code
   first, but the mechanism is not specific to it.
3. The 1–2 pt line between the rail and the panes. (Separate; see the end.)

Read [CLAUDE.md](../CLAUDE.md) first. The constraint that shapes everything
below is its opening rule: **tmux owns everything, the GUI owns nothing.**

---

## What made this design possible

Everything in this section was measured on **tmux 3.6a** on 2026-07-28, on an
isolated `-L cctest` server, not read from documentation. The mechanism was the
whole question, so it was settled first.

### tmux pushes format changes, so nothing has to be polled

`refresh-client -B name:what:format` registers a subscription on a control mode
client. tmux then sends `%subscription-changed` whenever the format's value
changes. **VERIFIED** — this is the raw stream from the test:

```
%subscription-changed agent $0 @0 0 %0 : claude^Aworking^A/Users/joey/…
%subscription-changed agent $0 @1 1 %1 : claude^Aneeds-input^A/Users/joey/…
%subscription-changed agent $0 @0 0 %0 : claude^Adone^A/Users/joey/…
```

The line is `%subscription-changed <name> <session> <window-id> <window-index>
<pane-id> : <value>`. Pane id is `-` for a window-scoped subscription.

Properties that matter, all **VERIFIED**:

| Property | Value |
|---|---|
| `what` | empty (session), `%0` (one pane), `%*` (all panes), `@0`, `@*` |
| On subscribe | tmux immediately emits the current value for every matching item — no priming query needed |
| Compound formats | Work. Several fields joined by U+0001 in one subscription; the whole line re-fires when any field changes |
| Rate limit | At most once per second, per the man page. A throttle we get for free |
| Removal | `refresh-client -B name` with no `what`/`format` |

### A pane-scoped variable at window scope means "the active pane"

`refresh-client -B wpath:@*:"#{pane_current_path}"` yields one line per window
carrying the **active pane's** path, and re-fires when the active pane changes.
**VERIFIED** — split a window, subscribed, then `select-pane`:

```
%subscription-changed wpath $0 @0 0 - : /Users/joey/.claude/jobs/…^Azsh
%subscription-changed wpath $0 @0 0 - : /Users/joey/Code/blog^Azsh
```

This is the same rule CLAUDE.md already records for `#{pane_id}` in a
`list-windows` format. It removes an entire pane→window mapping layer.

### tmux will hold arbitrary state for us, keyed to a pane

`set-option -p -t %0 @agent_state working` sets a user option on a pane;
`#{@agent_state}` reads it back and is the empty string on panes that never had
one. Window-level `-w` works the same way. **VERIFIED.**

This is the load-bearing point for the architecture. Agent state does **not**
become GUI-authored state — it becomes *tmux* state, written by whoever knows
it, read by anyone attached. A plain `tmux attach` in another terminal sees the
same values, and a status-line format could render them. The invariant holds.

Setting an option produces **no** notification on its own; only a subscription
reports it. **VERIFIED** (`%window-renamed` arrived in the same stream, so the
harness was working and the absence is real, not a missed message).

### A hook running inside a pane can address that pane

tmux exports `TMUX` and `TMUX_PANE` into every pane, and any child process
inherits them — including a hook Claude Code spawns. **VERIFIED** end to end: a
stand-in hook script run inside a pane wrote `@agent_state`, and a control mode
client received the push, with no knowledge on either side of the other.

```
hook wrote working to %0 (server=/private/tmp/…/cctest,4252)
```

### Claude Code is visible without any configuration at all

**VERIFIED** on the live machine: a pane running Claude Code reports
`#{pane_current_command}` as the bare version string:

```
w=@9 p=%14 cmd=[2.1.220] path=[/Users/joey/Code/tmux-gui]
```

and `claude --version` prints `2.1.220 (Claude Code)`. So a pane whose current
command matches `^\d+\.\d+\.\d+$` is running Claude Code, and the string is its
version.

This is a **fragile** signal — it depends on how the CLI happens to set its
process title, which nobody promised and which can change in any release. It is
used only for the thing it can be wrong about cheaply: "there is an agent here",
and as a liveness check on state written by a hook. It never decides *which*
state to show.

### Git is cheap, but not free

**VERIFIED** on this repo: `git status --porcelain=v2 --branch
--untracked-files=normal` runs in **15 ms** and yields everything the second
line needs in one call:

```
# branch.oid 0d2e81ee…
# branch.head main
# branch.upstream origin/main
# branch.ab +0 -0
```

15 ms is per repo, on a small repo, on a warm cache. Across ~15 open windows on
a loop it is no longer negligible, which is what the scheduling section is for.

### Prior art already on this machine

The user has **Otty** installed, whose Claude Code integration solves the same
problem by reporting to the app over IPC. Its hook script is shipped readable
inside the bundle and was read as reference. Two things were taken from it:

- The state vocabulary `processing | idle | awaiting` is the right shape. This
  design uses `working | done | needs-input` for the same three.
- **A `Stop` hook does not mean the turn ended.** Claude Code fires `Stop` when
  the main agent yields while a `Task` subagent is still running, so a naive
  Stop→idle mapping reports "done" repeatedly during a long turn. The payload's
  `background_tasks` still lists `"type":"subagent","status":"running"` in that
  case. This is a fact about Claude Code, not about Otty, and the hook here
  handles it the same way.

Nothing else is borrowed; the transport here is tmux, not an app-private IPC,
which is what keeps the state visible to every tmux client instead of one app.

---

## Architecture

Three new units, each with one job, none of them touching AppKit except the last.

```
Attache/Tmux/
  TmuxSubscriptions.swift   register/parse subscriptions; no policy
Attache/Status/
  GitStatus.swift           run git, parse porcelain v2 → GitSummary
  GitStatusService.swift    cache, scheduling, backoff, optional fetch
  AgentState.swift          @agent_state + sniffing → AgentBadge
  AgentHookInstaller.swift  merge our hook into ~/.claude/settings.json
Attache/UI/
  SidebarRows.swift         SidebarWindowRow grows a second line
```

### Where the new state is allowed to live

`TmuxWindow` **does not change.** It is a faithful mirror of tmux and adding a
Git field to it would be the first lie in the file. Git state is genuinely
external — it belongs to the filesystem, not to tmux — so it travels beside the
window, not inside it:

```swift
/// Everything drawn on a window row that tmux is not the source of.
struct WindowDecoration: Equatable {
    var git: GitSummary?      // nil = not a repo, or not looked at yet
    var agent: AgentBadge?    // nil = no agent in this window
}
```

`SessionSidebarView.Entry` gains `decorations: [String: WindowDecoration]`
keyed by window id. `Entry` is already a view model rather than a mirror, so
this is the right shelf for it.

Agent state is a different case and deliberately so: it lives in tmux as
`@agent_state`, arrives through the same control mode connection as everything
else, and `AgentBadge` is only the parse of it. The GUI authors neither.

### Data flow

```
Claude Code hook ──set-option -p @agent_state──> tmux
                                                  │
tmux ──%subscription-changed──> TmuxControlClient ─┴─> TmuxSessionConnection
                                                          │
                    ┌─────────────────────────────────────┤
                    ▼                                     ▼
             AgentState.parse                      pane_current_path
                    │                                     │
                    │                              GitStatusService
                    │                            (serial queue, cached)
                    └──────────────┬──────────────────────┘
                                   ▼
                          WindowDecoration
                                   ▼
                  SessionSidebarView.Entry → SidebarWindowRow
```

### The two subscriptions

Registered by `TmuxSessionConnection` right after the control client attaches,
alongside the existing initial `list-windows`:

```
refresh-client -B tgWin:@*:"#{pane_current_path}"
refresh-client -B tgPane:%*:"#{@agent_state}\001#{@agent_kind}\001#{@agent_at}\001#{pane_current_command}"
```

Window scope for the path, because the active pane is the one whose repo the
row should describe, and tmux resolves that for us. Pane scope for the agent,
because a window with four panes can have an agent in any of them and the row
has to speak for all of them.

Names are prefixed `tg` so they cannot collide with a subscription another
control mode client on the same server registered.

### Aggregating panes to a row

A window row shows one agent badge. When several panes in it have state, the
most urgent wins, in this order:

`needs-input` > `working` > `done` > none

Rationale: the badge exists to answer "does anything here want me". A window
where one pane is blocked on a permission prompt and another is happily working
wants you, and burying that under "working" would defeat the feature. Elapsed
time comes from the winning pane's `@agent_at`.

### Deciding an agent is gone

`@agent_state` is a value in tmux, so it survives the process that wrote it. A
Claude Code killed with `^C` never runs a `SessionEnd` hook and leaves `working`
behind forever.

Two independent guards, because either alone fails:

1. The hook clears the options on `SessionEnd`. Handles the ordinary exit.
2. **The GUI ignores `@agent_state` on a pane whose `pane_current_command`
   does not look like an agent.** This is what the fragile sniffing signal is
   actually for — it is allowed to be wrong about *which* agent, and it is
   still right about whether any foreground process is there at all. A pane
   sitting at a `zsh` prompt shows no badge whatever its options say.

Guard 2 makes guard 1 an optimisation rather than a correctness requirement,
which is the right way round.

---

## Feature 1 — the second line

Layout **A** from [the mockup](mockups/sidebar-rows.html), chosen 2026-07-28:
Git text owns line two, the agent is a coloured dot at the end of line one.
Line two never changes meaning, so the row's shape is constant and the eye
learns where to look once.

### Geometry

`SidebarWindowRow.height` goes from **27 pt to 40 pt**: 4 pt top, 15 pt name
line, 1 pt, 14 pt status line, 5 pt bottom. The index label moves to the top
line and stops being vertically centred against the whole row.

The default sidebar is **168 pt** wide (`AppSettings.defaultSidebarWidth`), and
after the 6 pt row inset and the 28 pt index column the second line has about
**110 pt**, or roughly 20 monospace characters at 10.5 pt. That is the real
constraint and the mockup's slider exists to make it obvious. Priority when it
does not fit, most droppable last:

1. dirty counts `+3 ~1` — never truncated, they are 5 characters
2. ahead/behind `↑2` — never truncated
3. branch name — truncated **from the left**, so `…/glass-note` survives where
   `post/glass…` would not. Long branch names in this workflow are
   `type/topic`, and the topic is the part that identifies it.

### What is shown

| Case | Line two |
|---|---|
| Clean repo | `main ✓` |
| Dirty | `main +3 ~1` — staged/added, then modified-unstaged |
| Ahead/behind | `main +3 ~1 ↑2` |
| Not a repo | `~/Code · not a repo`, in the faint colour |
| Not looked at yet | blank — never a spinner; the row must not flicker on every rebuild |

Counts come from one `git status --porcelain=v2 --branch` parse. `+` is
`staged + added`, `~` is unstaged modifications, untracked files are counted
into neither and appear only in the tooltip — a repo with a `node_modules` that
is not ignored would otherwise permanently read `+4000`.

### Refreshing without burning the battery

Decided rather than asked, because the answer follows from the numbers:

- **On path change.** The window subscription pushes it; refresh that repo.
- **FSEvents on the repo root**, debounced 750 ms. Catches both working-tree
  edits and `.git` changes (commit, branch switch, stage, fetch) with one
  stream. One stream per *distinct* repo root, not per window.
- **A 15 s backstop poll**, visible rows only.
- **Paused entirely** when the window is occluded or the app is hidden. There
  is nobody to show it to.
- **Auto-backoff**: a repo whose `git status` takes over 200 ms has its
  interval multiplied by 4, logged once. A large monorepo must not make the
  rail the slowest thing in the app.

All git work is on one serial background queue, coalesced per repo root, with
the result cached by root. Never on the main thread and never on the tmux
reader queue — CLAUDE.md's rule about keeping `%output` off the main thread
cuts both ways.

### `↑` and `↓`, honestly

`# branch.ab` is measured against the last `git fetch`, not against the remote.
Without fetching, `↓0` means "nothing known to pull", which reads as "nothing
to pull" and is a different claim.

Chosen 2026-07-28: **a background fetch, off by default, with a switch.**

- `AppSettings.gitAutoFetch` — default **false**
- `AppSettings.gitAutoFetchMinutes` — default 10

While off, the tooltip says `↓ unknown — last fetch 47m ago` rather than
implying zero. While on, `git fetch --quiet --no-tags` runs per repo on the
interval, never on a repo whose last fetch failed within the backoff window, and
never for a remote that prompted for credentials — one interactive prompt from a
sidebar is one too many, so the fetch runs with `GIT_TERMINAL_PROMPT=0` and
`GIT_SSH_COMMAND` set to batch mode, and a repo that fails that way is marked
and skipped until the app restarts.

---

## Feature 2 — agent state

### The badge

A 7 pt dot at the trailing end of line one, where the existing activity dot
already lives. It replaces the activity dot when an agent is present; tmux's
"unseen output" flag is the less specific statement of the two.

| State | Colour | Motion |
|---|---|---|
| `needs-input` | amber `#e8a33d` | breathing, 1.5 s |
| `working` | blue `#5aa9e6` | a spinning ring rather than a dot |
| `done` | green `#5fbf7f` | none; fades out after 5 minutes |
| present, state unknown | `faintText` | none |

"Present, state unknown" is the zero-config case: sniffing found an agent, no
hook is installed, so the app says the one thing it actually knows. This is the
row that makes installing the hook look worth it.

The tooltip carries the words: `Claude Code · waiting for you · 14s`.

### Both mechanisms, decided 2026-07-28

Sniffing alone cannot separate "thinking" from "waiting for you", which is the
distinction the whole feature exists for. Hooks alone leave a fresh install
blank. So:

- **Sniffing** answers *is there an agent, and is it still alive*. No setup.
- **The hook** answers *what is it doing*. Setup, once.

### The hook

Shipped in the app bundle as a readable script and copied to
`~/.claude/hooks/tmuxgui-agent-state.sh` — readable on purpose, as Otty does,
because it runs on every hook event and the user should be able to audit it.

```sh
#!/bin/sh
# Attaché — reports agent state into tmux, where the GUI can see it.
# $1 = working | needs-input | done | clear
[ -n "$TMUX_PANE" ] || exit 0        # not in tmux; nothing to report to

state="$1"
input=$(cat)                          # Claude passes the hook payload on stdin

# A Stop with a subagent still running is not the end of the turn — Claude
# fires one whenever the main agent yields. Reporting it as done makes the
# badge flicker green through a long turn.
if [ "$state" = done ] &&
   printf '%s' "$input" | tr -d ' \t\n' | grep -q '"type":"subagent","status":"running"'
then
    state=working
fi

if [ "$state" = clear ]; then
    tmux set-option -pu -t "$TMUX_PANE" @agent_state 2>/dev/null
    tmux set-option -pu -t "$TMUX_PANE" @agent_kind  2>/dev/null
    exit 0
fi

tmux set-option -p -t "$TMUX_PANE" @agent_state "$state" 2>/dev/null
tmux set-option -p -t "$TMUX_PANE" @agent_kind  claude   2>/dev/null
tmux set-option -p -t "$TMUX_PANE" @agent_at    "$(date +%s)" 2>/dev/null
exit 0
```

Every tmux call is `2>/dev/null` and the script always exits 0: a hook that
fails must never be able to break the user's Claude Code session.

Event mapping:

| Claude Code event | State |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | `working` |
| `PermissionRequest`, `Notification` | `needs-input` |
| `Stop` | `done` (unless a subagent is still running) |
| `SessionStart` | `working` |
| `SessionEnd` | `clear` |

### Installing it, decided 2026-07-28: one click, with a backup

Settings gains an **Agents** page with an install button. What it does, in
order:

1. Copy `~/.claude/settings.json` to
   `~/.claude/settings.json.tmuxgui-backup-<ISO8601>`.
2. Parse with `JSONSerialization` into `[String: Any]` and **preserve every
   key it does not recognise**. This file currently holds hooks belonging to
   Otty, ccpet, `code-rules-check`, and `banned-word-reminder`, plus
   `statusLine`, `permissions`, `enabledPlugins` and more. Rewriting it from a
   typed model would destroy all of it. Only `hooks.<event>` arrays are
   touched, and only by appending.
3. Skip if already present, matched on the script path, so the button is
   idempotent.
4. Write to a temp file and rename, so an interrupted write cannot leave a
   truncated settings file.

The dialog shows the exact JSON to be appended before writing anything, and an
**Uninstall** removes only entries whose command contains our script path.

This is the part of the plan with the most potential to do real damage — it
edits a config file several other tools depend on — so it gets a unit test with
a fixture copy of the real file, asserting byte-identical round-tripping of
every untouched key.

### Not specific to Claude Code

`@agent_state` and `@agent_kind` are a two-option convention, not a Claude
Code feature. Anything that can run `tmux set-option` can participate — Codex
and grok both run in these panes and both have hook or wrapper points. The GUI
reads `@agent_kind` only to choose a tooltip word; an unknown kind still gets
the right coloured dot. Nothing about Claude Code is special-cased in the app.

---

## Settings added

| Key | Default | What it does |
|---|---|---|
| `TmuxGUISidebarShowsGit` | `true` | The second line at all |
| `TmuxGUISidebarShowsAgent` | `true` | The dot at all |
| `TmuxGUIGitAutoFetch` | `false` | Background `git fetch` |
| `TmuxGUIGitAutoFetchMinutes` | `10` | How often, when on |

Turning both off returns the rail to 27 pt single-line rows exactly as it is
today, which is also the fallback if any of this turns out to be noisier in
practice than it looks in a mockup.

---

## Verification plan

Reading the code is not verification. Per CLAUDE.md, what will actually be run:

**Headless, by the agent:**

- A `Tools/SubscriptionCheck` harness on the `%subscription-changed` parser,
  in the same shape as the existing `ReplyCheck` and `LayoutCheck` tools: real
  captured lines in, parsed structs out, including the `-` pane id, an empty
  trailing field, and a value containing a literal ` : `.
- A `Tools/GitStatusCheck` harness over `porcelain=v2` fixtures: clean, dirty,
  detached HEAD, no upstream, merge conflict, renamed file, and a repo that is
  not a repo.
- The settings-merge test described above.
- An end-to-end run against an isolated `-L` server, driving the hook script by
  hand and asserting the app's parsed state — the same test already written
  once by hand while researching this.

**Needs the user's eyes, and will be handed over as a checklist:**

- Whether 40 pt rows make the rail feel heavy with twenty windows open.
- Whether the amber breathing dot is noticeable without being irritating.
- Whether the left-truncated branch name reads correctly at 168 pt.
- Whether the dot and the accent fill of the selected row fight each other.

---

## Risks worth stating now

| Risk | Standing |
|---|---|
| `pane_current_command` reporting a bare version is undocumented and can change | Only used for "an agent is here" and liveness; the feature degrades to no badge, never to a wrong one |
| A hook fires on every tool call, so it runs constantly | It is one `tmux set-option`, forked and forgotten; the 1 s subscription rate limit absorbs bursts on the GUI side |
| FSEvents on a repo with a huge working tree | 750 ms debounce plus the >200 ms auto-backoff; measure before shipping, do not assume |
| Editing `~/.claude/settings.json` | Backup, preserve-unknown-keys, atomic write, idempotent, uninstall, fixture test. Highest-care item in the plan |
| 40 pt rows halve how many windows fit | The setting turns it off; the mockup is there to decide before code is written |

---

## The seam between the rail and the panes

Investigated separately. Diagnosis and fix are recorded in the commit that
removes it, not here — it is a defect, not a design.
