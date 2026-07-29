# Agent details in the sidebar

Design, 2026-07-29. Everything in "Measured" below was run on this machine
against tmux 3.6a and Claude Code 2.1.220; everything else is marked.

Companion mockup, drawn at real point sizes:
`scratchpad/sidebar-agent-mockup.html`.

## What this adds

- **Per window** — which model the agent is running, how full its context is,
  what the session has cost. A third line on the row, present only while an
  agent is.
- **Per account** — the 5-hour and weekly rate-limit windows, each with a mark
  showing how much of that window's *time* has passed. Bottom of the rail.

Lines added and removed, session duration, effort level and output style go in
the row's tooltip. At the default 168pt rail the third line holds three fields.

## Where the numbers come from

Claude Code hands a JSON object on stdin to whatever `statusLine.command`
names. It is the only place it publishes cost, context and rate limits — the
hook payloads this app already reads carry `session_id`, `cwd` and a tool name
and nothing else. So the statusline is not the convenient route, it is the only
route.

### The real payload

Captured 2026-07-29 from Claude Code 2.1.220, ids removed:

```json
{
  "session_id": "…", "transcript_path": "…", "version": "2.1.220",
  "cwd": "/private/tmp/…/proj",
  "model": { "id": "claude-opus-5[1m]", "display_name": "Opus 5 (1M context)" },
  "workspace": { "current_dir": "…", "project_dir": "…", "added_dirs": [] },
  "effort": { "level": "xhigh" },
  "output_style": { "name": "default" },
  "thinking": { "enabled": true },
  "fast_mode": false,
  "exceeds_200k_tokens": false,
  "cost": { "total_cost_usd": 0, "total_duration_ms": 56786,
            "total_api_duration_ms": 0,
            "total_lines_added": 0, "total_lines_removed": 0 },
  "context_window": { "total_input_tokens": 0, "total_output_tokens": 0,
                      "context_window_size": 1000000, "current_usage": null,
                      "used_percentage": null, "remaining_percentage": null },
  "rate_limits": { "five_hour": { "used_percentage": 69, "resets_at": 1785294000 },
                   "seven_day":  { "used_percentage": 31, "resets_at": 1785708000 } }
}
```

1280 bytes, compact, **no newline anywhere in it**.

Four things in that object contradict what this design assumed before it was
captured, and each one changes code:

- **`used_percentage` is `null`, not absent**, in a session that has not sent a
  message yet. So is `current_usage` and `remaining_percentage`. A parser that
  only handles a missing key reports 0% for every fresh session — a wrong
  number, which is worse than no number.
- **`resets_at` is epoch seconds.** No ISO 8601 handling is needed. The parser
  still accepts a string of digits, because that costs one line.
- **`display_name` is `"Opus 5 (1M context)"`** — nineteen characters, where
  this design had assumed something like `Opus 5`. The row shortens it at the
  first ` (`.
- **`context_window_size` exists** (1000000 here), which makes the tooltip able
  to say `340k / 1M` rather than only a percentage.

`rate_limits` holds exactly `five_hour` and `seven_day` on this account. An
Opus-specific weekly window has been rumoured elsewhere and did not appear.

## The transport

A shell script writes the payload into a tmux **pane option**; the GUI reads it
over the control connection it already has. Same shape as `@agent_state`, and
for the same reason: the value belongs to tmux, so `tmux show-options -p -t
%42` prints it from any terminal and CLAUDE.md's opening rule survives a
feature that looks like it needs local state.

**The script parses nothing.** It writes the JSON through verbatim and Swift
parses it. That is what makes this work on a machine that is not this one:

- **No `jq`, no `python3`, no dependency at all.** An extractor written in
  shell needs one of them, and whichever it needs is a machine where the
  feature silently does not work.
- `JSONSerialization` is a real parser; a `sed` pipeline is not, and this
  payload carries user-authored text.

Newlines are stripped before the write anyway (`tr -d '\n\r'`, needs nothing
installed). The captured payload has none, but a control-mode notification is
line-based and a future pretty-printed payload would break the read loop.

The payload names a path and a session id. It is never logged, never written to
a file by this app, and nothing outside the fields listed above is displayed.

### One option, no global one

```
@agent_stat   the statusline JSON, newlines stripped
```

Rate limits are account-wide, so every agent pane's payload carries the same
two windows and the footer takes the freshest it can see. That deletes the
global option, the freshest-wins logic in shell, and the question of whether
`#{@cc_usage}` resolves through tmux's option inheritance.

`AgentDetector.paneFormat` gains `#{@agent_stat}`.

### Churn

Token counts move on every render, so a naive pipeline would rebuild the rail
every five seconds per agent pane. The payload is parsed into a **quantized**
`AgentStats` — context to whole percent, cost to cents — and `WindowDecoration`
is already `Equatable`, so a rebuild only happens when a number a person could
see has changed. No timestamp is written; liveness is the existing
`pane_current_command` check.

## Compatibility

| What is in `settings.json` | What TmuxGUI does |
| --- | --- |
| A custom statusline — coralline, ccstatusline, any script | Wrap it. Same stdin, stdout passed through byte for byte, exit status preserved. The terminal looks exactly as it did. |
| No `statusLine` at all | Wrap nothing, and render a minimal line — see below. |
| `statusLine.type` is not `"command"` | Refuse, explain, change nothing. |

Wrapping is agnostic: the inner command runs through `sh -c` with the original
stdin. Nothing in this design is specific to coralline; coralline is simply
what is installed here.

**The no-statusline case cannot be silent.** Measured: a `statusLine.command`
that prints nothing leaves a **blank row** where the status line would be. So a
wrapper that only reports would cost such a user one row of screen for nothing.
It therefore renders a minimal line of its own:

- with `jq` — `dir · branch · Model · ctx N% · $C`
- without `jq` — `dir · branch`, which needs no parser
- switchable off, with the Settings text saying plainly that off means a blank
  row

Reporting to the sidebar never needs `jq` in either case.

### Living with a setting other people also edit

- The inner command is recorded in
  `~/.claude/hooks/tmuxgui-statusline.conf`, not baked into the script, so it
  can be read and edited outside the app.
- If the user later runs `/statusline`, the wrapper is replaced and the numbers
  stop arriving. Nothing breaks. Settings detects it and offers a re-wrap.
- Installing twice is idempotent — a command already naming our script is not
  wrapped again.
- Another tool wrapping the same setting composes: ours runs theirs.
- `settings.json` is backed up first, by the mechanism `AgentHookInstaller`
  already has.
- **Install takes effect immediately on sessions that are already running** —
  measured, see below. No restart instruction is needed anywhere in the UI.

## The script

`~/.claude/hooks/tmuxgui-statusline.sh`, generated beside the existing
`tmuxgui-agent-state.sh`:

```sh
#!/bin/sh
# TmuxGUI — feeds the sidebar the numbers Claude Code publishes only here.
#
# A wrapper. Whatever statusline was configured before is recorded in
# tmuxgui-statusline.conf, run with the same stdin, and its output printed
# unchanged, so the line in your terminal does not change. Remove it in
# Settings, or restore statusLine.command from the backup beside settings.json.

input=$(cat)

# Report, and never let reporting affect what is drawn. Nothing is parsed here:
# TmuxGUI reads this JSON in Swift, so this script needs jq about as much as it
# needs awk, which is not at all.
if [ -n "$TMUX_PANE" ]; then
    printf '%s' "$input" | tr -d '\n\r' | {
        read -r line
        tmux set-option -p -t "$TMUX_PANE" @agent_stat "$line" 2>/dev/null
    }
fi

. "$(dirname "$0")/tmuxgui-statusline.conf" 2>/dev/null   # sets INNER
[ -n "$INNER" ] || exec "$(dirname "$0")/tmuxgui-statusline-minimal.sh"
printf '%s' "$input" | sh -c "$INNER"
```

Every tmux call is silenced and the script always reaches the inner command: a
reporting wrapper that can break the status line it wraps is worse than no
wrapper. Same rule the existing hook script is written to.

**Measured:** the `tmux set-option` costs **5.7 ms** against a live server with
a 1.3 KB value, where coralline's own render is **33 ms**. So the wrapper adds
about a sixth to something that happens every five seconds. The write stays
synchronous; backgrounding it would buy 5 ms and cost a race between panes over
which snapshot lands last.

## What the app grows

New:

| File | What it is |
| --- | --- |
| `TmuxGUI/Status/AgentStats.swift` | The parsed payload and the two usage windows. Foundation only. |
| `TmuxGUI/Status/AgentStatusLineInstaller.swift` | Install, detect, remove, restore. Reuses the backup helper. |
| `TmuxGUI/UI/UsageGaugeView.swift` | One bar with a burn mark. |
| `Tools/AgentStatsCheck/main.swift` | Parser cross-check. |

Changed: `AgentState.swift` (format), `AgentStateStrategy.swift` (evidence
gains the raw payload; the screen strategy leaves it nil),
`WindowDecoration.swift` (`stats`), `TmuxSessionConnection.swift` (carries it,
exposes the freshest usage), `SidebarRows.swift` (third line, tooltip),
`SessionSidebarView.swift` (footer), `AppSettings.swift` (two toggles),
`BehaviourPage.swift` (install / remove).

### The row

Height becomes `27 / 40 / 53`. Three lines only when the window has a live
agent *and* a payload, so a rail with no agents is the rail that exists today.
The instance decides its height in `init` and stores it in `rowHeight` — the
pattern already in the file, and the reason a setting change cannot
desynchronise a row from its container.

```
Opus 5  ▰▱▱ 34%  $2.14
```

Right to left, because the right-hand fields have a known width:

- **Cost** right-aligned, measured, never truncated.
- **Context** a 26pt bar plus the percent. Blue under 70, orange from 70, red
  from 90. **Absent entirely while `used_percentage` is null** — a fresh
  session shows no bar rather than an empty one.
- **Model** takes what is left, shortened at the first ` (` so
  `Opus 5 (1M context)` reads `Opus 5`, then truncated from the tail.

Below roughly 150pt of rail the model drops out, then the bar, leaving the
cost. Measured at layout, the way `statsLabel` already works.

Tooltip gains: full model name, `340k / 1M` context, cost, lines added and
removed, session duration, effort level, output style.

**Known cost:** a row grows and shrinks as an agent starts and stops, moving
the rows below it. It happens at the same moment the dot appears, so it reads
as one event rather than two.

### The footer

Above the New session button, hidden when the setting is off or nothing has
been seen:

```
5h                69%   1h20m
▰▰▰▰▰▰▰▰▰▰▰▰▰│▱▱▱▱
Week              31%   4d18h
▰▰▰▰▰│▱▱▱▱▱▱▱▱▱▱▱▱▱▱
```

The mark is `1 - (resets_at - now) / length`, clamped, length 18000s and
604800s. Bar shorter than the mark means burning slower than the clock — the
only drawing that answers "will I run out early". Fill colour follows usage
alone: green under 50, yellow under 75, red at 75 and above, matching
coralline's thresholds so the two never disagree on screen.

## Settings

Behaviour → Agent status gains a third block: **Session details** with install
/ remove and the command it will wrap shown verbatim; **Show model, context and
cost on window rows** (default on); **Show account usage at the bottom**
(default on).

## Measured

Run 2026-07-29 on this machine. tmux work used an isolated server
(`-L tmuxgui-test` on every command); the Claude Code work used a throwaway
project directory with `.claude/settings.local.json`, so the real
`~/.claude/settings.json` was never written to. Confirmed afterwards that it
still reads `bash ~/.claude/coralline/statusline.sh`.

| # | Question | Result |
| --- | --- | --- |
| 1 | Does a ~2KB single-line value survive a control-mode subscription? | **Yes.** 1864 bytes set via argv, read back through `refresh-client -B 'name:%*:#{@agent_stat}'`: two `%subscription-changed` lines, payload **byte-exact** and still valid JSON. Subscription it is; no polling fallback needed. |
| 2 | Does the statusline subprocess inherit `TMUX_PANE`? | **Yes**, directly: the capture script logged `TMUX_PANE=[%0]` on every render. Previously only inferred. |
| 3 | What is actually in the payload? | Captured — see above. Four assumptions corrected. |
| 4 | Is `resets_at` epoch or ISO? | **Epoch seconds.** |
| 5 | Do running sessions pick up a changed statusline? | **Yes, no restart.** Both editing the script and rewriting `statusLine.command` took effect within ~14s in a session that was already open. |
| 6 | Does a statusline printing nothing cost anything? | **Yes — one blank row.** This is why the no-statusline case renders a minimal line instead of staying silent. |

Built and watched running, 2026-07-29:

| # | What | Result |
| --- | --- | --- |
| 7 | The wrapper, run in a real pane | Exit 0, stdout **byte-identical** to the inner command's, and `@agent_stat` holding the 1280-byte payload byte for byte. |
| 8 | Wrapping coralline specifically | 230 bytes out, **identical** with and without the wrapper. |
| 9 | An inner command that fails | Its exit status survives (`exit 3` in, 3 out). |
| 10 | A pretty-printed payload | Newlines stripped, still valid JSON in the option. |
| 11 | No `jq` anywhere on `PATH` | Minimal line degrades to `dir · branch`, no crash. (`jq` turns out to be at `/usr/bin/jq` on macOS 26, so this path is rarer than expected.) |
| 12 | Install through the Settings button | `statusLine.command` rewritten, `refreshInterval` preserved, backup taken, coralline recorded in the `.conf`. |
| 13 | Seven live Claude Code panes | All reporting model, context and cost within 20s, **with no restart**. |
| 14 | Coralline in those panes afterwards | Drawing exactly as before, every segment intact. |
| 15 | `AccountUsage.fresher` against real snapshots | Seven panes reported 5-hour usage between 0% and 65%; the rule correctly picked the 1% reading, whose window resets later — the 63–65% figures were the closing reading of a window that had already rolled over. This is the defect the rule exists for, seen in the wild on the first run. |
| 16 | Parser cross-check | 56 cases pass. `AgentStateCheck` (44), `ReplyCheck` and `RenameStringCheck` still pass too. |

## What the review found

An independent Codex review on 2026-07-29 raised six findings. Every one was
checked against the code before being acted on, and **all six were real**.

| Severity | What | Now |
| --- | --- | --- |
| crash | `total_cost_usd` was scaled to cents *before* the bounds check, so a finite `1e308` became infinity and trapped on the way to an `Int`. Reproduced: the check tool exited on SIGTRAP with its output still buffered. | `cents()`, which scales then bounds. Five cases added. |
| data loss | The recovery record could not tell "there was no status line" from "the record is missing", so a deleted `.conf` made uninstall remove the user's whole `statusLine` object. | `Recovery` has three cases, and `unavailable` refuses rather than guesses. |
| data loss | Ownership was a substring test on the script's file name, so any command *mentioning* the wrapper — another tool composing around it — read as ours and was overwritten. | `classify` matches the exact forms this app writes; anything else naming the script is `unrecognised` and refused. |
| hang | The wrapper called tmux synchronously with no deadline, and sourced a config it advertises as user-editable — so a wedged server or a stray `exit` could stall or kill the status line it exists not to disturb. | The tmux write is backgrounded and detached; the record is read with `sed`, never executed. |
| wrong data | `agentStats(forWindow:)` inferred a winner from one `moreUrgent` comparison, which cannot separate "more urgent" from "identical" — and `@agent_at` has one-second resolution, so ties happen. A tie silently preferred the later pane, hiding the numbers when that pane was the one without them. | Compared both ways round; a tie prefers the pane that reported. |
| stale UI | The gauges read the clock only when the parsed numbers changed — and the numbers deliberately do not change often — so an idle account froze its countdown. | A 30-second timer while the gauge is in a window. |

The two data-loss findings are why `StatusLineRecovery` is now its own file with
its own cross-check (`Tools/StatusLineCheck`, 46 cases): it is the same shape of
danger as `TerminalReply` and `TmuxRenameString` — every way it fails is silent
— and the project's answer to that shape is a table of cases.

Fixing the record format left one machine holding a file in the old shape.
Migrating it by hand was the right call rather than teaching the parser a legacy
format that never shipped, and the install path refuses rather than degrading
when it meets one: writing "there was no status line" into the record on a
re-install is a loss one step removed from the action that caused it.

Not established, and why:

- **A session with no statusline configured anywhere.** Both isolation routes —
  `CLAUDE_CONFIG_DIR` and a replacement `HOME` — hit the login screen, and
  running an OAuth flow to answer a layout question is not worth a second
  authorization. What #6 measured is enough to choose the default; what remains
  unknown is only whether that row is reserved even when no statusline is set.
- **The wrapper's latency cost.** Measured once the wrapper exists.

Still to do before this is called working: the parser cross-check
(`Tools/AgentStatsCheck`), the three compatibility cases, and watching the
running app — an agent starts and the row grows with numbers in it, stops and
the row shrinks, and the footer marks sit where the clock says.

## Out of scope

- **Agents other than Claude Code.** Codex and the rest publish no equivalent
  object, so they keep the dot and the state word. Nothing here assumes Claude
  Code beyond the payload shape, so a second agent that grows a statusline is a
  parser and a table entry.
- **History.** The footer shows the current windows, not a graph over time.
