# CLAUDE.md

Notes for an agent picking this project up. Read [README.md](README.md) first
for what the app does; this file is about how to work on it without breaking
the things that were expensive to get right.

## The one idea

tmux owns everything. The GUI owns nothing.

Window lists, which window is active, pane layouts, pane sizes, scrollback,
window names — every one of those lives in tmux and arrives as a control mode
notification. The interface renders what it is told and translates clicks into
tmux commands. It never predicts, never caches a value tmux could contradict,
and never applies a change locally before tmux confirms it.

That is what makes `tmux attach` from an ordinary terminal agree with the app,
and it is the invariant to protect. If a feature seems to need locally authored
state, look for the tmux format variable that already holds it. The one
deliberate exception is the set of tab-hidden window ids in
`SessionViewController`, and it is commented as such.

## Layers

```
TmuxServer            one connection per tmux session
 └─ TmuxSessionConnection    control mode client + window list for one session
     ├─ TmuxControlClient    child process, read loop, command/reply pairing
     ├─ TmuxOutputRouter     pane id → surface, thread-safe, off the main queue
     └─ TmuxMetrics          throughput and stall measurement

MainViewController     session rail + the current session's view
 └─ SessionViewController    window tab strip + pane grid for one session
     ├─ WindowTabBarView     second-level tabs
     └─ PaneGridView         panes placed on tmux's character grid
         └─ TmuxPaneSurface  one pane ↔ one libghostty surface
```

`TmuxGUI/Tmux/` has no AppKit imports and should stay that way.
`TmuxGUI/UI/` is the only place that touches views.

## Rules that are not style preferences

**Target tmux by id, never by name.** `$10`, `@25`, `%42`. Names are arbitrary
user text interpolated into a command line; ids match `[$@%]\d+` and cannot
carry a quote, a space, or a newline. This removes command injection as a
category rather than escaping around it. `TmuxCommand.quote` exists for the one
place real text has to be sent — renaming — and nothing else should need it.

**Decode `%output` on bytes.** tmux escapes control characters and backslash as
`\ooo` but passes bytes above 0x7f through raw, so a payload is not necessarily
valid UTF-8 on its own. Round-tripping it through `String` replaces those bytes
with U+FFFD and corrupts the stream. `TmuxOctal.decode` takes `[UInt8]` for
this reason; do not "simplify" it.

**Keep `%output` off the main thread.** It arrives on the pipe reader queue and
goes straight into `TmuxOutputRouter`, which is why the app survives 19 MB/s.
`InMemoryTerminalSession.receive` already serialises internally. Hopping to main
to do a dictionary lookup would put every byte behind whatever the UI is doing.

**The GUI and tmux must agree on the column count exactly.** One column of
disagreement makes every wrapped line break in the wrong place, and the damage
accumulates into unreadable overdraw wherever a TUI rewrites a region.
`PaneGridView` counts in device pixels and *measures* the overhead a surface
adds beyond `columns × cellWidth` rather than assuming it. Do not replace that
measurement with a constant.

**Anything destructive needs a confirmation and separate wording.** Closing a
tab hides it. A window may have an agent mid-run; there is no undo.

## Building and running

```sh
xcodebuild -project TmuxGUI.xcodeproj -scheme TmuxGUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

/tmp/dd/Build/Products/Debug/TmuxGUI.app/Contents/MacOS/TmuxGUI
```

Run the binary directly rather than `open`-ing the bundle: stdout stays
attached, which is where the throughput report and any `NSLog` land.

The app sandbox must stay off (`ENABLE_APP_SANDBOX = NO`). A sandboxed process
can neither spawn tmux nor reach its socket under `/private/tmp/tmux-<uid>/`.

`libghostty-spm` is a submodule pinned to a known-good commit. After cloning:
`git submodule update --init --recursive`.

The `.xcodeproj` is still hand-maintained — it was copied from the libghostty
sample and edited by hand. Migrating it to XcodeGen is item 2 in TODO.md; until
that lands, treat the pbxproj as something to change deliberately and check,
not something to let a tool rewrite.

## Verifying a change

Reading the code is not verification. Three things actually work:

**The layout parser has a cross-check against a live server.** It walks every
window tmux currently has and compares parsed geometry against `list-panes`.
Run it after touching `TmuxLayout.swift`:

```sh
swiftc -O -o /tmp/layoutcheck TmuxGUI/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
/tmp/layoutcheck
```

**tmux itself is the oracle for anything protocol-shaped.** Before writing code
against a notification or a command, run it: `tmux -C attach -t '=name'` over a
pipe prints the raw stream, and `tmux list-panes -F '...'` shows exactly what a
format yields. Several of the bugs listed below were found this way and none of
them were guessable from the documentation.

**UI behaviour needs real events.** `osascript ... click at` is unreliable
here; `cliclick` (Homebrew) delivers events the app actually receives:

```sh
cliclick c:x,y                  # click
cliclick dc:x,y                 # double-click
cliclick kd:cmd t:4 ku:cmd      # ⌘4
cliclick m:x1,y1 dd:x1,y1 m:x2,y2 du:x2,y2   # drag
```

Then screenshot and look: `screencapture -x -o -R x,y,w,h out.png`. Move the
window to a known position first — the coordinates are global and a second
display puts it at a negative x.

Always create a throwaway tmux session for tests and kill it afterwards. The
user's real sessions have long-running agents in them.

## Traps already paid for

Each of these is commented at the site. They are recorded here because every
one of them presents as "the code is obviously correct and yet".

- **macOS 26 sibling overdraw.** A view that draws gets a backing layer 66pt
  taller than itself, for the title-bar scroll-edge effect, and the overhang is
  not clipped. Whichever sibling is added last wins. A view can have a correct
  frame, `isHidden == false`, alpha 1, and confirmed `draw(_:)` calls, and still
  render nothing. Check `addSubview` order first.
- **libghostty claims ⌘ keys.** Its terminal view treats them as candidates for
  its own keybinds before the main menu is consulted. `TmuxTerminalView`
  overrides `performKeyEquivalent` to give the menu first refusal.
- **`%client-session-changed` starts with a client name**, not a session id, and
  it is broadcast to every client on the server. Parsing it like
  `%session-changed` points every connection at whichever client moved last.
- **`move-window -t $10 4` is silently wrong.** The target must be
  `session:index`; without the colon tmux reads it as the single token `$104`
  and does nothing at all — no error.
- **Selecting on mouse down destroys the gesture.** Selection sends a tmux
  command, tmux replies, the strip rebuilds, and the view being dragged is gone.
  Select on mouse up.
- **`clickCount == 1` is not a reliable click test.** Synthesised events carry
  0. Track that a press started on the view instead.
- **Autocorrect eats Return in inline editors.** The system completion popup
  takes the key that was supposed to commit. Disable text completion and the
  field editor's substitutions.
- **`capture-pane` returns one line per row including blanks.** Painting all of
  them parks the cursor on the bottom row, so a prompt redrawn after SIGWINCH
  lands at the bottom of an empty screen. Trim trailing blanks.

## Conventions

- **English everywhere** — code, comments, commit messages, UI strings, docs.
  This is not a tool for one language's speakers.
- **Comments explain why, not what.** Most of the comments in this codebase
  exist because the obvious reading of the code is wrong; keep that bar. If a
  comment could be deleted without losing information, delete it.
- **Commit messages carry the reasoning**, especially the parts that took
  measurement to establish. The history is the only place a future reader finds
  out that something was verified rather than assumed.
- **Say what was measured and what was inferred.** "Verified against tmux 3.6a"
  and "should work" are different claims and the difference matters.

## Open work

See [TODO.md](TODO.md).
