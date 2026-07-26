# TmuxGUI

A native macOS window over a real tmux server. Attach to the same session from
any ordinary terminal and you get the ordinary tmux — the processes never
notice this app exists.

```
tmux session  →  a row in the left rail
tmux window   →  a tab in the top strip
tmux pane     →  a split in the content area
```

The interface holds no state of its own. Clicking, reordering, renaming and
splitting all turn into tmux commands and only take visible effect when tmux
reports back — so `prefix + c` typed in another terminal adds a tab here by
exactly the same path a click on **+** does.

## How it works

tmux ships with **control mode** (`tmux -C`). In it, tmux stops drawing and
speaks a plain-text protocol to whatever program is on the other end.
Rendering is [libghostty](https://ghostty.org), used through the
[`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) Swift package —
its `.inMemory` backend owns no pty and simply asks for bytes.

That leaves three wires:

| Direction | tmux side | app side |
|---|---|---|
| output | `%output %42 <bytes>` | `InMemoryTerminalSession.receive(data)` |
| input | `send-keys -t %42 -H <hex>` | `write` callback |
| geometry | `refresh-client -C <cols>x<rows>` | `resize` callback |

## Features

- **Three levels, synchronised both ways.** Anything done in tmux shows up
  here, and anything done here is a tmux command.
- **Panes placed on tmux's own character grid.** A pane at cell `(x, y)` sized
  `columns × rows` goes at exactly `(x·cellWidth, y·cellHeight)`. Both sides
  work from one grid, so the splitters cannot drift apart.
- **Drag a splitter** → `resize-pane`. tmux follows the GUI, not the reverse.
- **Drag a tab** → `move-window`. **Double-click a tab** → `rename-window`.
- **Closing a tab only hides it — it never kills anything.** A window may have
  an AI agent mid-run and there is no undo for that. Killing is a separate
  context-menu item with explicit wording and a confirmation. Hidden windows
  come back from the counter at the right of the strip.
- **Scrollback.** A pane is seeded with tmux's history the first time it is
  shown.
- **Shortcuts**, alongside your own tmux `prefix` bindings rather than
  replacing them: ⌘T new window, ⌘W hide tab, ⌘1-9 select window,
  ⌘⇧[ ] previous/next window; ⌃⌘1-9 select session, ⌃⌘[ ] previous/next
  session, ⌘⇧N new session; Shift+PageUp/PageDown/Home/End for scrollback.
- **Activity dots** reuse tmux's own activity flag, so they mean the same
  thing as the `#` in a tmux status line.
- **No title bar.** The window-tab strip occupies that band instead.

## Throughput probe

Control mode multiplexes every pane in a session onto one pipe, so the risk
that could sink the whole design is not bandwidth — it is one busy pane
starving the one you are looking at. **Measure → Run Throughput Probe** runs an
A/B against a synthetic heartbeat: one pane printing a byte every 50ms, first
alone, then while another pane in the same session floods.

| | median gap | p99 | worst | flood output |
|---|---|---|---|---|
| A · heartbeat alone | 57 ms | 59 ms | 59 ms | — |
| B · heartbeat + flood | 57 ms | 58 ms | 59 ms | 170 MB in 8 s (**19.4 MB/s**) |

**No degradation.** The baseline is 57ms rather than 50ms because
`printf .; sleep 0.05` carries about 7ms of shell overhead — 57ms *is* the
heartbeat period, and it did not move under 19.4 MB/s of interference.

Measured at the point bytes arrive in the app, not through rendering. Local
socket, tmux 3.6a, Apple Silicon. Not yet measured over ssh.

## Layout of the code

`TmuxGUI/Tmux/` — everything that has nothing to do with AppKit:

- `TmuxOctal.swift` — byte-level codec. tmux escapes control characters and
  backslash as `\ooo`, but passes bytes above 0x7f through raw, so decoding has
  to happen on bytes; a round trip through `String` replaces anything that is
  not valid UTF-8 on its own with U+FFFD and corrupts the stream.
- `TmuxNotification.swift` — control mode message parsing.
- `TmuxLayout.swift` — window layout parsing (`{}` left-right, `[]` top-bottom).
- `TmuxControlClient.swift` — child process, read loop, command/reply pairing.
- `TmuxOutputRouter.swift` — thread-safe pane-id → surface map; `%output` goes
  straight there without touching the main thread.
- `TmuxSessionConnection.swift` — one session, one connection.
- `TmuxServer.swift` — every session's connection.
- `TmuxMetrics.swift` — throughput and stall measurement.

`TmuxGUI/UI/` — the AppKit half.

`Tools/LayoutCheck/` — cross-checks the layout parser against a live server:
for every window it can see, compare the geometry the parser derives for each
pane with what `list-panes` reports.

```sh
swiftc -O -o /tmp/layoutcheck TmuxGUI/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
/tmp/layoutcheck
```

## Building

Needs Xcode and tmux.

```sh
git clone --recurse-submodules https://github.com/XueshiQiao/tmux-gui.git && cd tmux-gui
xcodebuild -project TmuxGUI.xcodeproj -scheme TmuxGUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Already cloned: `git submodule update --init --recursive`.

**The app sandbox must be off.** A sandboxed process can neither spawn tmux nor
reach its socket under `/private/tmp/tmux-<uid>/`.

## Traps worth knowing about (each is commented at the site)

- On macOS 26 a sibling view that draws gets a backing layer 66pt taller than
  itself — the title-bar scroll-edge effect — and that overhang is not clipped.
  Whichever view is added last wins. The tab strip was invisible for a while
  because the content area was painting over it.
- libghostty's terminal view claims ⌘ combinations before the main menu sees
  them. A subclass gives the menu first refusal.
- libghostty reserves window padding by default, and at a normal font size that
  costs a whole cell. One column of disagreement between the app and tmux makes
  every wrapped line break in the wrong place, which shows up as unreadable
  overdraw wherever a TUI keeps rewriting a region. The grid now *measures*
  the surface's overhead rather than assuming it is zero.
- `%client-session-changed` starts with a *client* name, not a session id, and
  it is broadcast to every client. Parsing it like `%session-changed` points
  every connection at whichever client moved last.
- `move-window` needs `session:index`; without the colon tmux silently does
  nothing.
- Selecting a tab on mouse *down* rebuilds the strip from tmux's reply and
  destroys the view mid-gesture. Selection happens on mouse up.

## Working on it

[CLAUDE.md](CLAUDE.md) covers the architecture, the invariants worth
protecting, how to verify a change, and the traps already paid for.
[TODO.md](TODO.md) is the open work.

## Known limits

- Pane content is re-snapshotted with `capture-pane` after a geometry change:
  tmux reflows on resize but does not make the program inside repaint.
- The probe result appears in `NSAlert.runModal()`; main-queue work queues up
  behind the modal run loop while it is open.
- The stall figure in the sidebar footer only means something while a pane is
  producing output. An idle pane inflates it. The A/B probe is the real number.
- `capture-pane` replies are decoded as `String`, so invalid UTF-8 becomes
  U+FFFD. This affects snapshots only; live `%output` takes the byte path.
- Not built yet: search, copy mode, a settings UI, multiple app windows.
