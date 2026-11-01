# Agent Hub: Multi-Agent Hook Abstraction, Centralized State Machine, and Multi-Client Delivery

Design and verification note, 2026-11-01. Extends [sidebar-status-design.md](sidebar-status-design.md).
Read [CLAUDE.md](../CLAUDE.md) first — everything below preserves its opening invariant:
**tmux owns everything; the GUI owns nothing.**

---

## 1. Goals and Architectural Stance

Attaché originally tracked Claude Code alone, either by scraping `capture-pane` output or via a
Claude-only shell script (`~/.claude/hooks/tmuxgui-agent-state.sh`). That design hit three ceilings:

1. **Multi-agent reality.** Daily workflows run **Claude Code**, **Antigravity (`agy`)**, and **Grok**
   side by side in the same tmux server, each with its own hook configuration layout, lifecycle event
   vocabulary, process `p_comm` signature, and `stdout` reply contract.
2. **State-machine edge cases.** Naive event-to-state mapping marks `SessionStart` as `working`
   (leaving fresh or abandoned panes permanently `working`), misses `StopFailure` (API errors / rate
   limits) and `StopCancelled` (user interrupts in Grok), treats interactive question tools
   (`AskUserQuestion`, `ExitPlanMode`, `ask_question`) as `working` instead of `needs-input`, and
   suffers cross-agent contamination when Grok's built-in Claude compatibility layer executes
   `~/.claude/settings.json`.
3. **Peer multi-client future (macOS, Android, iOS).** Desktop `Attaché.app` must **not** be the
   authority that computes agent state. Agents run on the host machine (a MacBook, a headless Mac mini,
   or a Linux server), and a mobile client (Android or iOS Attaché) must see identical, already-decided
   agent states even when desktop `Attaché.app` is closed or never installed on that host. Desktop,
   Android, and iOS are **peer consumers**.

---

## 2. Three-Layer Pipeline (Scheme A Today, Ready for Scheme B)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 1 — Agent Adapters & Signal Sources                                    │
│   • ClaudeHookProvider      (~/.claude/settings.json)                        │
│   • AntigravityHookProvider (~/.gemini/config/hooks.json, group-scoped)      │
│   • GrokHookProvider        (~/.grok/hooks/attache-status.json)              │
│   • Client-side signals: Claude OSC #{pane_title} watchdog + Screen fallback │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ invocations + stdin JSON + env
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 2 — Centralized Receiver & State Machine (`attache-agent-hub`)         │
│   • Standalone CLI executable bundled in `Attaché.app/Contents/MacOS/`       │
│     and staged atomically to `~/.config/attache/bin/attache-agent-hub`       │
│     (portable POSIX `/bin/sh` twin deployed over SSH to remote hosts)        │
│   • Event-driven (zero idle RAM / zero daemon lifecycle management)          │
│   • Normalizes agent dialects -> runs `AgentStateReducer` -> emits canonical │
│     `AgentStateAction` + agent-required synchronous `stdout` JSON            │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ canonical `AgentStateAction`
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 3 — Downstream Sink Abstraction (`AgentStateSink`)                     │
│   • [Active — Scheme A] `TmuxAgentStateSink`: writes `@agent_state`,         │
│     `@agent_kind`, `@agent_at`, `@agent_why` to the owning tmux pane.        │
│     tmux itself is the 24/7 host state bus; macOS Attaché and SSH-based      │
│     Android/iOS clients receive `%subscription-changed` pushes directly.     │
│   • [Ready — Scheme B] `UnixSocketAgentStateSink`: non-blocking JSONL push   │
│     to `~/.config/attache/agent-hub.sock` whenever present, allowing a       │
│     future `attache-daemon` (WebSocket API, FCM/APNs push, lock-screen       │
│     approval replies) to subscribe without changing any hook or reducer.     │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why Scheme A needs no resident daemon today

`tmux` is already a resident process on every host running panes. Invoking `attache-agent-hub` on hook
boundaries takes a few milliseconds, persists the authoritative state into tmux pane options, and exits.
No background daemon has to be supervised, restarted after crashes, or opened through a firewall. When
Scheme B (`attache-daemon`) is later introduced for offline mobile push or WebSocket clients, it simply
binds `~/.config/attache/agent-hub.sock` and consumes the envelope stream `UnixSocketAgentStateSink`
already emits.

---

## 3. Measured Protocol Facts Across the Three Agents

All facts below were verified on 2026-11-01 against live sessions on macOS (`tmux 3.6a`, Claude Code
`2.1.308`, Antigravity CLI `agy`, Grok CLI `1.0.52`) and each tool's local reference documentation.

### 3.1 Process names (`#{pane_current_command}`)

| Agent | Measured `#{pane_current_command}` | Notes |
|---|---|---|
| **Claude Code** | `claude` or bare version `2.1.308` | Version string matches `N.N` or `N.N.N` digits/dots only. |
| **Antigravity** | `agy` | Binary is `agy` (alias `antigravity`). |
| **Grok** | `grok` or `grok-1.0.52-mac` | macOS `p_comm` truncates `grok-1.0.52-macos-arm64` to 15 bytes (`grok-1.0.52-mac`). Match `grok` or prefix `grok-`. |

### 3.2 Terminal OSC title (`#{pane_title}`)

Measured across 10 live `agy` panes (including an actively executing pane `%88`), 10 `claude` panes,
and 1 `grok` pane:

- **Claude Code** publishes dynamic Braille spinners (`U+2800..U+28FF`, or half-circles `U+25D0..U+25D3`)
  while a turn is running and switches to static `✳` (`U+2733`) the moment generation stops — **including
  when interrupted with `Esc`**, where Claude emits neither `Stop` nor `StopFailure`. It does *not*
  distinguish `done` from `needs-input` (both display `✳`).
- **Antigravity (`agy`)** and **Grok** never emit dynamic status titles (`agy` leaves the shell's
  `preexec` title `agy --dangerously-skip-permissions`; Grok sets `grok`).

Therefore `#{pane_title}` is used strictly as a zero-polling Claude signal inside `HookAgentStrategy`:
1. If an unhooked Claude pane shows a spinner glyph in `#{pane_title}`, report `working`.
2. If `@agent_state` is stuck on `working` (e.g. after `Esc` or legacy `SessionStart`) while
   `#{pane_title}` has settled back to `✳` past a 3-second prompt-submit grace window, clear the stale
   `working` state.

### 3.3 Hook configuration schemas & `stdout` contracts

| Dimension | Claude Code | Antigravity (`agy`) | Grok CLI |
|---|---|---|---|
| **Config path** | `~/.claude/settings.json` | `~/.gemini/config/hooks.json` | `~/.grok/hooks/attache-status.json` (`$GROK_HOME/hooks/`) |
| **Root shape** | Shared settings dict with `"hooks": { "<Event>": [MatcherGroup] }` | Shared dict of **named hook groups**: `"attache-status": { "<Event>": ... }` | Dedicated Attaché-owned file: `{ "hooks": { "<Event>": [MatcherGroup] } }` |
| **Event array shape** | Always `[ { "matcher"?: "...", "hooks": [Handler] } ]` | **Mixed**: `SessionStart`, `PreInvocation`, `PostInvocation`, `Stop` take flat `[Handler]`; `PreToolUse`, `PostToolUse` take `[ { "matcher": "...", "hooks": [Handler] } ]` | Always `[ { "matcher"?: "...", "hooks": [Handler] } ]` |
| **Synchronous `stdout` requirement** | None (empty `stdout`, exit `0`) | **Mandatory valid JSON on `stdout`**: `PreToolUse` requires `{"decision":"allow"}`; `Stop` requires `{"decision":"stop"}` (any value != `"continue"`); others accept `{}` | Passive on empty `stdout` with exit `0` |
| **Cross-tool hazard** | Shared with 4+ user tools & `statusLine`; symlinks common | Shared across named user hook groups | **Grok loads `~/.claude/settings.json` by default** (`10-hooks.md` L69) and exports `GROK_HOOK_EVENT` / `GROK_SESSION_ID` |

**Fail-open shell invocation**: Every installed command invokes `attache-agent-hub` so that even if the
user drags `Attaché.app` to Trash and deletes `~/.config/attache` without uninstalling hooks first, the
shell wrapper still exits `0` and (for `agy`) prints the required fallback JSON (`{"decision":"allow"}` /
`{"decision":"stop"}` / `{}`).

---

## 4. Layer Specifications

### 4.1 Shared Module Layout (`AgentHub/` + `AgentHubCLI/`)

`AgentHub/` contains pure `Foundation` / `Darwin` Swift with **no AppKit and no libghostty imports**,
and explicit `nonisolated` annotations so it compiles identically into:

1. `attache-agent-hub` (`AgentHub/` + `AgentHubCLI/main.swift`) — standalone CLI binary embedded at
   `Attaché.app/Contents/MacOS/attache-agent-hub` and copied atomically to
   `~/.config/attache/bin/attache-agent-hub`.
2. `Attache` (`Attaché.app`) — uses the exact same `AgentHookProvider` catalog, pure JSON merge/unmerge
   transforms, and process matchers for Settings previews, installation, and sidebar detection.
3. Check tools (`Tools/HookInstallCheck`, `Tools/AgentHubCheck`, `Tools/AgentStateCheck`).

### 4.2 Canonical Event & State Machine (`AgentStateReducer`)

| Agent(s) | Event & Payload Condition | Reducer Action | Resulting `@agent_state` |
|---|---|---|---|
| All | Payload carries non-empty `agent_id`, `subagentType`, `subagent_type`; or `SubagentStart` / `SubagentStop`; or `CLAUDE_JOB_DIR` set | `.ignore("subagent")` | *(unchanged)* |
| Claude | Invoked with `--agent claude`, `GROK_SESSION_ID` or `GROK_HOOK_EVENT` present, and native Grok hook installed | `.ignore("grok-compat-duplicate")` | *(unchanged; handled by native Grok hook)* |
| Claude | Invoked with `--agent claude`, `GROK_SESSION_ID` or `GROK_HOOK_EVENT` present, native Grok hook absent | Reclassify `agent = grok` | Stamps `@agent_kind = grok` |
| All | `SessionStart` with `source == "compact"`, or `PreCompact` / `PostCompact` | `.ignore("compact")` | *(unchanged)* |
| All | `SessionStart` (normal startup / resume / clear) | `.register` | Unsets `@agent_state` (ready/idle), sets `@agent_kind`, `@agent_at`, `@agent_why=SessionStart` |
| Claude, Grok | `UserPromptSubmit` | `.transition(.working)` | `working` |
| Antigravity | `PreInvocation` | `.transition(.working)` | `working` |
| All | `PreToolUse` where tool is `AskUserQuestion`, `AskQuestion`, `ask_user_question`, `ask_question`, `ExitPlanMode`, `exit_plan_mode` | `.transition(.needsInput)` | `needs-input` |
| All | `PreToolUse` (all other tools), `PostToolUse`, `PostToolUseFailure` | `.transition(.working)` | `working` |
| Claude, Grok | `PermissionRequest` | `.transition(.needsInput)` | `needs-input` |
| Claude, Grok | `Notification` with `permission_prompt`, `elicitation_dialog`, `agent_needs_input` | `.transition(.needsInput)` | `needs-input` |
| Claude, Grok | `Notification` with `idle_prompt` | `.transition(.done)` | `done` |
| Claude, Grok | `Notification` (other types, e.g. `task_complete`) | `.ignore("passive-notification")` | *(unchanged)* |
| All | `Stop` (including `agy` `USER_CANCELED` / `NO_TOOL_CALL`) | `.transition(.done)` | `done` |
| Claude, Grok | `StopFailure` (API error, rate limit, disconnect) | `.transition(.done)` | `done` |
| Grok | `StopCancelled` (Ctrl+C / Esc interrupt, permission rejected, max turns) | `.transition(.done)` | `done` |
| Claude, Grok | `SessionEnd` | `.clear` | Unsets `@agent_state`, `@agent_kind`, `@agent_at`, `@agent_why` |

### 4.3 Pane Resolution & Sinks

1. **`AgentPaneResolver`**:
   - Reads `TMUX_PANE` (validating `%<digits>`) and extracts the socket path from `TMUX`
     (`<socket_path>,<pid>,<session_idx>`).
   - Fallback when a hook runner strips `TMUX_PANE`: queries `tmux list-panes -a -F "#{pane_pid}\t#{pane_id}"`
     and walks process ancestry (`KERN_PROC_PID` via `sysctl`) from `getppid()` up to `PID 1` until a pane root PID matches.
   - **Foreground-agent ownership guard (`paneAllowsAction`)**: before fanning a state change out to sinks,
     queries `#{pane_current_command}` (`TIOCGPGRP`). When the pane's foreground process is a known agent
     *different* from the hook's `actionKind` (measured on `%25`: interactive Claude `2.1.308` spawning a
     headless `agy -p` or `agy` spawning `grok`), sink writes are skipped while required synchronous `stdout`
     replies still go out, so a child agent never clobbers its parent pane's `@agent_*` options.
2. **`TmuxAgentStateSink`** (active):
   - Executes a single `tmux` invocation chaining `set-option -p -t %N ...` (`;` separated) so all four
     pane options (`@agent_state`, `@agent_kind`, `@agent_at`, `@agent_why`) update atomically in **one**
     fork/exec (~2 ms total) rather than four separate `tmux` processes.
3. **`UnixSocketAgentStateSink`** (Scheme B extension socket):
   - Checks `stat()` on `$ATTACHE_HUB_SOCKET` (default `~/.config/attache/agent-hub.sock`). When absent,
     returns immediately at zero cost. When a listener (`attache-daemon`) is bound, connects a non-blocking
     `AF_UNIX` `SOCK_STREAM` socket and writes a single JSON line:
     ```json
     {"v":2,"pane":"%88","tmuxSocket":"/private/tmp/tmux-501/default","agent":"agy","action":"transition","state":"working","reason":"PreInvocation","at":1793541900,"sessionId":"54893f02-...","cwd":"/Users/joey/Code/Attache"}
     ```

### 4.4 Client-Side Subscription & `#{pane_title}` Watchdog (`HookAgentStrategy`)

- `AgentDetector.paneFormat` appends `#{pane_title}` at index `6` (keeping indices `0..5` stable).
- **Measured on Claude Code `2.1.308` (pane `%13`)**: recent Claude Code versions can keep `#{pane_title}`
  static as `✳ <topic>` throughout an entire active working turn (`PostToolUse`). Consequently:
  1. When `badge.state == nil` (no `@agent_state` written yet) and `#{pane_title}` begins with an active
     spinner glyph (`U+2801..U+28FF` Braille frames or `U+25D0..U+25D3` quadrants), `HookAgentStrategy`
     reports `working` (`reason = "osc_title_working"`).
  2. `✳` (`U+2733`) reconciles a stuck `working` state to `done` (`reason = "osc_title_idle"`) **only** when
     `AgentEvidence.sawTitleSpinnerInCurrentTurn` recorded an actual title spinner during that working turn —
     preventing false `done` transitions on Claude Code `2.1.308` setups that never spin `#{pane_title}`,
     while recovering `<1s` from `Esc` interrupts on setups that do.
  3. Any pre-v2 `@agent_state == "working"` written by legacy `SessionStart` (`@agent_why == "SessionStart"`)
     is normalised to `nil` (registered/idle) immediately on the client.

---

## 5. Verification Checklist

Every change to `AgentHub/` or `Attache/Status/` must pass all five checks below before completion:

1. **Pure Reducer & Sink Protocol Check (`AgentHubCheck`)**:
   - Exercises all three agent providers (`claude`, `agy`, `grok`), `stdout` JSON replies, subagent and
     compaction filtering, Grok Claude-compat deduplication/reclassification, interactive question tools,
     `StopFailure` / `StopCancelled`, single-command `tmux` option batching, and `UnixSocketAgentStateSink`
     delivery to a live temporary Unix domain socket.
2. **Config Merge & Non-Destructive Preservation Check (`HookInstallCheck`)**:
   - Verifies round-trip `merge` / `unmerge` / `validateShape` for Claude (`~/.claude/settings.json`,
     including legacy `tmuxgui-agent-state.sh` migration), Antigravity (`~/.gemini/config/hooks.json`
     preserving unrelated named groups and mixed flat/grouped event arrays), and Grok
     (`~/.grok/hooks/attache-status.json`), plus in-memory round-trip against the machine's real files.
3. **Subscription & Strategy Reconciliation Check (`AgentStateCheck` + `ScreenStateCheck`)**:
   - Verifies `AgentDetector` recognition of `claude`, bare versions, `agy`, and `grok-1.0.52-mac`,
     cross-agent stale option rejection, and Claude `#{pane_title}` (`⠋` vs `✳`) reconciliation.
4. **End-to-End Isolated tmux Server Check (`tmux -L attache-hub-e2e`)**:
   - Runs the compiled `attache-agent-hub` binary inside an isolated `-L attache-hub-e2e` tmux server
     across simulated `claude`, `agy`, and `grok` lifecycles (including `$TMUX_PANE`-stripped ancestry
     fallback) and verifies exact `@agent_*` values and `stdout` bytes, then runs
     `tmux -L attache-hub-e2e kill-server`.
5. **Full App + Helper Build & Signing Layout Check**:
   - `xcodegen generate` followed by `xcodebuild ... build`, verifying
     `Attaché.app/Contents/MacOS/attache-agent-hub` is built, executable, and covered by
     `.github/workflows/build.yml` inside-out signing.
