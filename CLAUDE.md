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
deliberate exception is the set of hidden window ids in
`SessionViewController`, and it is commented as such.

## Layers

```
TmuxServer            one connection per tmux session
 └─ TmuxSessionConnection    control mode client + window list for one session
     ├─ TmuxControlClient    child process, read loop, command/reply pairing
     ├─ TmuxOutputRouter     pane id → surface, thread-safe, off the main queue
     └─ TmuxMetrics          throughput and stall measurement

MainViewController     the two-level rail + the current session's panes
 ├─ SessionSidebarView       both levels: sessions, and the windows of any open one
 │   └─ SidebarRows          the heading / window / hidden-count row views
 └─ SessionViewController    one session's content half
     ├─ TitleBandView        28pt drag band over the panes; draws nothing
     └─ PaneGridView         panes placed on tmux's character grid
         └─ TmuxPaneSurface  one pane ↔ one libghostty surface
```

The rail draws the window level but does not own it: it outlives every session
it displays, so hiding, killing and the hidden-window set live in
`SessionViewController`, and `MainViewController.wireSidebar` routes each click
to the controller of the session the *row* belonged to — never to whichever
session happens to be current when the callback fires. `inSession` makes that
controller if there is not one yet, because the rail lists the windows of every
session it has open and acting on one of them is not conditional on having
looked at it.

Two things in the UI are authored locally and nothing else is: the hidden window
ids in `SessionViewController`, and `expandedSessions` in `SessionSidebarView`.
tmux has no opinion about either.

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

**Anything destructive needs a confirmation and separate wording.** Hiding a
window takes its row out of the rail and sends tmux nothing; killing is a
different menu item, worded as what it is, and asks first. A window may have an
agent mid-run; there is no undo. `closingTabKillsWindow` decides which of the
two comes first in the menu — it never removes either, because a preference
that silently deletes a capability is worse than one that reorders a menu.

## Building and running

```sh
xcodegen generate            # after a fresh clone, or any change to project.yml or Scripts/
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

**`project.yml` is the project; `TmuxGUI.xcodeproj` is a build artifact.**
It is gitignored and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) regenerates it. Change a build setting in `project.yml`
and regenerate — a change made in Xcode's build-settings editor lasts until the
next `xcodegen generate` and then vanishes, with no sign it was ever there.

`Scripts/normalize-libghostty.sh` needs a regenerate too: XcodeGen copies its
contents into the build phase, so an edited or freshly pulled script does
nothing until the project is rebuilt from `project.yml`.

Two things in `project.yml` are load-bearing and fail at *launch* rather than at
build, so a green build does not tell you they are still right:

- `ENABLE_APP_SANDBOX: NO`. `TmuxGUI/Entitlement.entitlements` is an empty
  `<dict/>`, so this setting is the only thing keeping the sandbox off.
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG $(inherited)"` on the Debug
  config. Without it `TmuxGUI/Debug/` and every `#if DEBUG` path compiles away
  silently and the inspector is simply not there.

`TmuxGUI/` is listed as a `syncedFolder`, Xcode 16's synchronized group: the
directory is the target member, so a new file compiles without editing
`project.yml`. Do not turn it into a file list.

## Verifying a change

Reading the code is not verification. Four things actually work:

**The layout parser has a cross-check against a live server.** It walks every
window tmux currently has and compares parsed geometry against `list-panes`.
Run it after touching `TmuxLayout.swift`:

```sh
swiftc -O -o /tmp/layoutcheck TmuxGUI/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
/tmp/layoutcheck
```

**`TerminalReply` has one too, and it is the file with the worst record in the
project.** It decides which bytes never reach the user's pane, so a false
positive there is a keystroke the app silently ate. Three defects shipped from
it in a single day — a cursor-position report that is byte-identical to
Shift-F3, a mouse filter that also swallowed the scroll wheel, and a digit run
that overflowed and killed the process. Every one would have been caught by a
case in this table. Run it after touching `TerminalReply.swift`, and add the
case *before* the fix:

```sh
swiftc -O -o /tmp/replycheck TmuxGUI/Tmux/TerminalReply.swift Tools/ReplyCheck/main.swift
/tmp/replycheck
```

The half that matters is `keystrokes`. A reply that leaks is a cosmetic
nuisance; a key that vanishes is the failure the file exists to prevent.

**`TmuxScreenReplay` has one, and it is the only part of a repaint that can be
checked without a screen.** It turns a `capture-pane` reply into the bytes a
surface is fed, so every defect in it is an off-by-one or a missing sequence —
a cursor row counted from zero on one side and one on the other, an erase that
should not have gone out, a separator that puts a blank line in the scrollback.
Run it after touching `TmuxScreenReplay.swift`:

```sh
swiftc -O -o /tmp/screenreplaycheck TmuxGUI/Tmux/TmuxPaneSnapshot.swift \
  TmuxGUI/Tmux/TmuxScreenReplay.swift Tools/ScreenReplayCheck/main.swift
/tmp/screenreplaycheck
```

What it cannot tell you is what libghostty then *does* with those bytes. That
needs the running app and someone looking at it.

**`TmuxRenameString` has one, and its important half is the list of streams it
must *not* touch.** It decides what never reaches a pane's surface — the same
power `TerminalReply` has over keystrokes, and the same way to fail. A sequence
that leaks is cosmetic; a byte of real output that gets eaten is silent and
unrecoverable. Run it after touching `TmuxRenameString.swift`, and put the
stream in `passthrough` before touching anything:

```sh
swiftc -O -o /tmp/renamestringcheck TmuxGUI/Tmux/TmuxRenameString.swift \
  Tools/RenameStringCheck/main.swift
/tmp/renamestringcheck
```

It splits every case at every byte boundary and again one byte per chunk,
because tmux cuts `%output` wherever its own buffer ends — including between the
`ESC` and the `k`.

**Screenshots need an awake display, and there is no way to wake one from
here.** `screencapture` answers `could not create image from display` and the
inspector's `/shot` composites the window to plain white — both of which read
as the app drawing nothing. Check before believing a blank capture:

```sh
system_profiler SPDisplaysDataType | grep -i 'display asleep'
```

`caffeinate -u` does not wake it, and neither `cliclick` nor
`osascript … System Events` works unless the process running them has been
granted Accessibility — an agent's shell usually has not, and the symptom is a
`-1712` AppleEvent timeout or cliclick's "Accessibility privileges not enabled"
warning followed by nothing happening. When that is the situation, say so and
hand the pixel-level checks to a human rather than reporting them as passed.

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
cliclick dd:x1,y1 dm:xa,ya dm:x2,y2 du:x2,y2   # drag
```

**A drag needs `dm`, not `m`.** This recipe used to read `m:` for the steps
between `dd` and `du`, and it silently does not work: `m` posts a *mouse moved*
event, which AppKit delivers as `mouseMoved(with:)`, so a view that implements
`mouseDragged(with:)` — every draggable thing in this app — sees nothing at all
and the gesture ends as a plain click. `dm` is the one that continues a drag.
Give it two or three intermediate points; one jump can land past the threshold
a view uses to tell a drag from a shaky click.

Then screenshot and look: `screencapture -x -o -R x,y,w,h out.png`. Move the
window to a known position first — the coordinates are global and a second
display puts it at a negative x.

**A self-capture cannot see through its own window.** The inspector's `/shot`
uses `CGWindowListCreateImage`, which composites that window and nothing
behind it, so on a translucent window it returns the material's no-backdrop
grey — the same picture at two window positions a thousand points apart,
differing by one step out of 255. Anything about translucency, blur or how the
chrome sits over a wallpaper needs `screencapture` (Screen Recording consent)
or a person. Say which one you had.

**Do not `screencapture` between `dd` and `du`.** Observed here: capturing
mid-drag sometimes ends the gesture, so the `du` arrives with nothing to deliver
to and the drop is lost. It looks exactly like the app dropping the action.
Capture the mid-drag state in one run and re-do the same drag without a capture
to check the result.

**Check what is frontmost before sending keystrokes.** `cliclick t:` and
`osascript ... keystroke` both go to whatever app is in front, and this app
loses front regularly during a test — anything the pointer touches that opens a
browser tab or a text-selection popup takes it. Every stray keystroke lands
somewhere real. `osascript -e 'tell application "System Events" to get name of
first application process whose frontmost is true'` before, and put the
`set frontmost of process "TmuxGUI" to true` in the *same* AppleScript as the
keystroke so nothing can get between them.

**Test against a throwaway tmux *server*, not a throwaway session, and reach it
with `-L` on every single command.** The user's real sessions have long-running
agents in them, and a session-level mistake is a server-level accident.

```sh
tmux -L tmuxgui-test -f /dev/null new-session -d -s probe   # create
tmux -L tmuxgui-test list-windows -a                        # inspect
tmux -L tmuxgui-test kill-server                            # clean up
```

`-L` on the create, `-L` on every query, `-L` on the cleanup. The flag is what
picks the server; leaving it off any one command sends that command to the
user's.

`TMUX_TMPDIR` is **not** an isolation mechanism and must not be used as one.
Verified on tmux 3.6a: it is honoured only when `-L` is *also* given. On its
own it is silently ignored and every command lands on the default server — so
`TMUX_TMPDIR=/tmp/mine tmux kill-server` destroys the user's server while
reading as though it could not possibly touch it. Since `-L` alone already
isolates, there is no reason to set `TMUX_TMPDIR` at all.

Note what this costs when it goes wrong: an agent editing this repo normally
*runs inside* one of those panes. A command that kills the server kills the
agent's own terminal mid-call, so the tool call never reaches the transcript —
the action is invisible in the very record you would search to find it. Assume
your own log has a hole exactly where the damage is.

## Traps already paid for

Each of these is commented at the site. They are recorded here because every
one of them presents as "the code is obviously correct and yet".

- **macOS 26 sibling overdraw.** A view that draws gets a backing layer 66pt
  taller than itself, for the title-bar scroll-edge effect, and the overhang is
  not clipped. Whichever sibling is added last wins. A view can have a correct
  frame, `isHidden == false`, alpha 1, and confirmed `draw(_:)` calls, and still
  render nothing. Check `addSubview` order first.
- **The sidebar's inset panel was the design, and then macOS 26 made it
  unusable.** On macOS 26 an `NSSplitViewItem` with sidebar behaviour draws the
  rail as an inset rounded panel, and `allowsFullHeightLayout` — which needs a
  toolbar, an empty one is enough — lifts it into the titlebar band so the
  traffic lights sit inside it. That was right, and deleting the panel to move
  the lights was wrong twice. It is gone now anyway, for a reason none of that
  touches: the panel arrives with the system's **Liquid Glass rim** around its
  inset margin, and that margin belongs to AppKit. On a translucent window the
  rim is a third kind of glass beside the rail's tint and the panes', and it
  cannot be tinted, covered or switched off. The rail is a plain split item and
  edge to edge; the window's `.fullSizeContentView` keeps the lights over it.
  Do not restore the panel to fix the lights — check where they actually are
  first.
- **Handing `NSSplitViewController` a split view brings the window up
  completely blank.** It creates and wires its own, in ways that setting
  `delegate` on a replacement does not reproduce, and there is no error: the
  window opens, the app runs, and nothing is drawn. `MainViewController`
  re-classes the instance AppKit already made instead — safe only because the
  subclass adds no stored properties and the instance really is a plain
  `NSSplitView`, which is checked on every launch.
- **A macOS material is not a pane of glass, and the two things people mean by
  "transparency" are separate.** `NSVisualEffectView` is a frosted sheet with an
  opacity of its own that no tint painted over it can reduce — a window at 15%
  tint over one still barely shows the desktop — and its blur is fixed per
  material with no API to change it. `CALayer.backgroundFilters` with a
  `CIGaussianBlur` is the public way to blur a window's backdrop at a radius of
  your choosing (public on macOS, not on iOS); `NSGlassEffectView` is macOS 26's
  own, and it tints the backdrop itself, so anything painted on top applies the
  colour twice. `WindowGlass` keeps all three apart and every drawing site asks
  it rather than deciding.
- **libghostty claims ⌘ keys.** Its terminal view treats them as candidates for
  its own keybinds before the main menu is consulted. `TmuxTerminalView`
  overrides `performKeyEquivalent` to give the menu first refusal.
- **tmux answers a control client with reply blocks it never asked for, and the
  `%begin` flags field is the only thing that says so.** `%begin <time> <number>
  <flags>`: flags is 1 when the block is the reply to a command *this* client
  sent — including when it fails, so `%error` carries 1 too — and 0 when it is
  not. Two things produce a 0: the attach handshake, and **every command tmux
  runs on its own behalf, which means one extra block per `select-pane` on a
  machine with `set-hook -g after-select-pane 'run-shell …'` installed.** Popping
  one completion per block therefore hands the next command its predecessor's
  reply, permanently, and the first casualty is the `list-windows` that follows
  `%window-pane-changed`: it receives an empty block, returns early on "no
  windows", and the model is left naming a pane tmux has already moved off. That
  presents as **the keyboard moving out of the pane the user just clicked**,
  about half a second later, with no undo and nothing in the log. Measured on
  tmux 3.6a against an isolated `-L` server, and a hook fired by *another*
  client sends no block here — only the connection that issued the command gets
  the extra one, which is why it looked like clicking was the trigger.
- **`%client-session-changed` starts with a client name**, not a session id, and
  it is broadcast to every client on the server. Parsing it like
  `%session-changed` points every connection at whichever client moved last.
- **`move-window -t $10 4` is silently wrong.** The target must be
  `session:index`; without the colon tmux reads it as the single token `$104`
  and does nothing at all — no error.
- **`window_layout` is not the layout on screen.** It is the *saved* one, and
  zoom does not change it: after `resize-pane -Z` on a two-pane 80x24 window it
  still reads `...{40x24,0,0,0,39x24,41,0,1}` while `list-panes` puts the zoomed
  pane at 80x24. `window_visible_layout` is what is being displayed, and
  `%layout-change` carries both — `<window-id> <saved> <visible> <flags>`.
  Reading the saved one is the column-count disagreement this codebase exists to
  avoid, at forty columns rather than one. Both are needed and for different
  questions: draw from the visible layout, but take the *pane set* from the saved
  one, because the visible layout of a zoomed window lists a single pane and
  anything that reads "which panes does this window have" from it will tear down
  the others. Selecting a window that was left zoomed sends no `%layout-change`
  at all, so `list-windows` has to ask for both too.
- **Selecting on mouse down destroys the gesture.** Selection sends a tmux
  command, tmux replies, the rail rebuilds, and the view being dragged is gone.
  Select on mouse up. The same applies to a reorder drag: the rail draws an
  insertion line while dragging and sends `move-window` once, on mouse up.
  Committing on every drag step is what the window-tab strip did, and it pulled
  the dragged view out from under the pointer on the first step.
- **`clickCount == 1` is not a reliable click test.** Synthesised events carry
  0. Track that a press started on the view instead.
- **Autocorrect eats Return in inline editors.** The system completion popup
  takes the key that was supposed to commit. Disable text completion and the
  field editor's substitutions.
- **libghostty answers as a terminal, and the answers go out as keystrokes.**
  The surface's write callback is the pane's keyboard, but libghostty is a real
  terminal and also speaks for itself on it — device attributes, cursor
  position, and, once a program enables mouse tracking, a pointer report on
  every refresh. tmux is the pane's actual terminal and has already answered,
  so the program gets a second reply it never asked for. Measured 2026-07-26:
  **705 unrequested `send-keys` to one pane in two minutes**, all of them SGR
  mouse reports. Harmless against a TUI, command-line text against a shell
  prompt. `TerminalReply` filters them out on the bytes. It cannot be done on
  provenance: a keystroke's write callback arrives asynchronously on the same
  queue as a mouse report, so the call stack carries nothing to key off.
- **`%output` is written for a terminal we are not.** tmux's wiki says it is
  "exactly what the application running in the pane sent to tmux", carrying
  escape sequences "as expected by tmux (so for `TERM=screen` or `TERM=tmux`)" —
  the pane's raw bytes, before tmux's own parser. libghostty emulates xterm. Line
  up the two escape tables and the *string*-introducing finals are `P X ] ^ _ k`
  for tmux against `P X ] ^ _` for Ghostty, so the gap is exactly `ESC k`,
  screen's window-rename string. Ghostty logs it as an unimplemented action,
  drops it, returns to ground, and draws the title behind it as ordinary text.
  With `TERM=tmux-256color` oh-my-zsh sends one before every command and one
  before every prompt, so every command's output arrived with the command name
  glued to its front and the working directory on the line beneath — which reads
  as `echo` being broken, not as a terminal gap. `TmuxRenameString` removes it.
  Three of its rules had to be measured, because the sequence does not behave
  like it looks: **BEL does not terminate it**, **any `ESC` does and is then
  reprocessed as a fresh sequence** (so there is no terminator to match, and the
  trailing `ESC \` is passed through as a bare ST that Ghostty no-ops), and **an
  unterminated one expires after five seconds** — without that last one a stray
  `ESC k` in front of a plain-text file eats the whole file, because plain text
  holds no escape byte to get out on. Verified on tmux 3.6a; the table diff is
  read from Ghostty's source at the pinned commit.
- **`TMUX_TMPDIR` without `-L` is ignored, silently.** It reads as isolation and
  is not. On 2026-07-26 an agent set it, believed it had a private server, ran
  cleanup without `-L`, and destroyed the user's tmux server and every agent
  running in it. Verified afterwards on tmux 3.6a: with the directory present
  and `$TMUX` set, `TMUX_TMPDIR=… tmux ls` lists the *real* sessions, while
  `TMUX_TMPDIR=… tmux -L probe ls` correctly resolves under the custom
  directory. `-L` is what isolates. See "Verifying a change".
- **`move-window` moves the active flag off the window it moves.** `-d` means
  "do not select the newly linked window", and a move is an unlink followed by
  a link — so moving the window that is *currently active* leaves it wherever
  it was asked to go with tmux's active flag handed to something else. Verified
  on tmux 3.6a: with w5 active, `move-window -b -d -s @4 -t t:1` puts w5 at
  index 1 and `window_active` on w1. A drag that moved the selection off the
  row being dragged is what this presents as. `TmuxSessionConnection` sends
  `select-window` afterwards when, and only when, the moved window was the
  active one.
- **`move-window -b` cannot append, and says nothing about it.** Given windows
  at 0-3, `-b -t t:5` does not put the window at 5 — it clamps to the last
  window and inserts before *that*. The end of a session is reachable only by a
  plain move (no `-b`) onto a free index, and a plain move onto an *occupied*
  one fails with `index in use` and a non-zero status. Both measured on tmux
  3.6a against an isolated `-L` server.
- **Hiding the active window used to undo itself.** Hiding sends tmux nothing
  about hiding — only a `select-window` for the row to move to — and the sync
  that follows ran before tmux could answer, so tmux still named the row that
  had just been hidden and the "tmux made it active again, put it back" rule
  fired on it. ⌘W therefore only ever switched windows. `hidingActiveWindow`
  is the latch that tells the two apart.
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
