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

**tmux draws the panes.** The content half is one terminal running a plain
`tmux attach` on a pty ghostty owns, so the splitters, every pane and the
cursor are tmux's own drawing — the app supplies a rectangle and nothing else.
The rail beside it is still driven by a control-mode connection, which is what
the app reads session and window lists from and what every click turns into.

The app used to render each pane itself from the `%output` stream, on a grid it
placed against tmux's layout. That half was removed on 2026-07-31 after
measurement settled it: copy mode and `display-popup` put *nothing at all* on
the control-mode stream, so they could not be drawn at any price.
[docs/embed-tmux-evaluation.html](docs/embed-tmux-evaluation.html) is the
evaluation, and `git log` before that date is where the pane renderer lives if
it is ever wanted again.

```
TmuxServer            one connection per tmux session
 └─ TmuxSessionConnection    control mode client + window list for one session
     └─ TmuxControlClient    child process, read loop, command/reply pairing

MainViewController     the two-level rail + the current session's content
 ├─ SessionSidebarView       both levels: sessions, and the windows of any open one
 │   └─ SidebarRows          the heading / window / hidden-count row views
 ├─ SessionModel             one session's state and commands; no view at all
 ├─ EmbeddedSessionViewController   one session's content half
 │   ├─ TitleBandView        28pt drag band over the terminal; draws nothing
 │   └─ TmuxTerminalView     the surface tmux draws the whole session into
 └─ ToolRailView             the right rail: one tool up, tab icons in the header row
     ├─ ConversationSidebarView   the window's agent conversation
     └─ GitToolView               lazygit in an app-owned terminal — not in tmux —
                                  opened on the current window's worktree root
```

`SessionModel` and the controller beside it are split on one line: the model
holds what the rail reads and the commands anything can send, the controller
holds the window. Anything that has to ask *is the user looking at this* — ⌘V,
⌘Z, split, zoom — belongs to the controller, because a window keeps naming a
first responder while another window has the keyboard.

The rail draws the window level but does not own it: it outlives every session
it displays, so hiding, killing and the hidden-window set live in
`SessionViewController`, and `MainViewController.wireSidebar` routes each click
to the controller of the session the *row* belonged to — never to whichever
session happens to be current when the callback fires. `inSession` makes that
controller if there is not one yet, because the rail lists the windows of every
session it has open and acting on one of them is not conditional on having
looked at it.

Three things in the UI are authored locally and nothing else is: the hidden
window ids in `SessionViewController`, `expandedSessions` in
`SessionSidebarView`, and which rail tool is up in `ToolRailView`. tmux has no
opinion about any of them. The Git tool's lazygit child is the app's own
process on purpose — inside tmux it would appear in every attached client and
outlive the app in their session lists.

`Attache/Tmux/` has no AppKit imports and should stay that way.
`Attache/UI/` is the only place that touches views.

## Rules that are not style preferences

**Target tmux by id, never by name.** `$10`, `@25`, `%42`. Names are arbitrary
user text interpolated into a command line; ids match `[$@%]\d+` and cannot
carry a quote, a space, or a newline. This removes command injection as a
category rather than escaping around it. `TmuxCommand.quote` exists for the one
place real text has to be sent — renaming — and nothing else should need it.

**Every preference goes in `SettingsFile`, never in `UserDefaults`.** The store
is `~/.config/attache.toml`: a file the person who owns these settings can
read, edit, diff, put in a dotfiles repository and restore by hand. Reaching for
`UserDefaults` for "just this one flag" puts a setting somewhere they cannot see
and cannot get back — which is exactly how the settings were lost that prompted
the move. The app's plist still exists and holds one thing: the window frames
AppKit writes through `setFrameAutosaveName`, which are not ours and have no
supported redirect.

**Anything destructive needs a confirmation and separate wording.** Hiding a
window takes its row out of the rail and sends tmux nothing; killing is a
different menu item, worded as what it is, and asks first. A window may have an
agent mid-run; there is no undo. `closingTabKillsWindow` decides which of the
two comes first in the menu — it never removes either, because a preference
that silently deletes a capability is worse than one that reorders a menu.

## Building and running

```sh
xcodegen generate            # after a fresh clone, or any change to project.yml or Scripts/
xcodebuild -project Attache.xcodeproj -scheme Attache -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

/tmp/dd/Build/Products/Debug/Attaché.app/Contents/MacOS/Attache
```

Run the binary directly rather than `open`-ing the bundle: stdout stays
attached, which is where the throughput report and any `NSLog` land.

**The app is `Attaché`; everything you type at it is `Attache`.** The accent is
on the product only — `Attaché.app`, `CFBundleName`, the menu bar, Finder. The
repository, the source folder, the target, the scheme, the bundle identifier
(`me.xueshi.attache`) and the executable inside the bundle are all plain ASCII,
so `pgrep`, `pkill -f`, `osascript … process "Attache"` and every path in a
build command work without an encoding to think about. Both spellings are
correct and they are not interchangeable: `process "Attaché"` finds nothing,
and `Attache.app` does not exist.

The accent on `PRODUCT_NAME` is load-bearing and looks like it is not.
`CFBundleName` is what AppKit draws as the bold app-menu title, and under
`GENERATE_INFOPLIST_FILE` it is always `$(PRODUCT_NAME)` — there is no
`INFOPLIST_KEY_CFBundleName`. Setting `CFBundleDisplayName` instead does not
move it: measured on macOS 26, the title stayed `Attache` above Hide and Quit
items reading `Attaché`, because `AppDelegate` builds the menu by hand with no
nib and spells those out. `EXECUTABLE_NAME` is what keeps the binary ASCII
underneath.

The app sandbox must stay off (`ENABLE_APP_SANDBOX = NO`). A sandboxed process
can neither spawn tmux nor reach its socket under `/private/tmp/tmux-<uid>/`.

`libghostty-spm` is a submodule pinned to a known-good commit. After cloning:
`git submodule update --init --recursive`.

**`project.yml` is the project; `Attache.xcodeproj` is a build artifact.**
It is gitignored and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) regenerates it. Change a build setting in `project.yml`
and regenerate — a change made in Xcode's build-settings editor lasts until the
next `xcodegen generate` and then vanishes, with no sign it was ever there.

`Scripts/normalize-libghostty.sh` needs a regenerate too: XcodeGen copies its
contents into the build phase, so an edited or freshly pulled script does
nothing until the project is rebuilt from `project.yml`.

Two things in `project.yml` are load-bearing and fail at *launch* rather than at
build, so a green build does not tell you they are still right:

- `ENABLE_APP_SANDBOX: NO`. `Attache/Entitlement.entitlements` is an empty
  `<dict/>`, so this setting is the only thing keeping the sandbox off.
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG $(inherited)"` on the Debug
  config. Without it `Attache/Debug/` and every `#if DEBUG` path compiles away
  silently and the inspector is simply not there.

`Attache/` is listed as a `syncedFolder`, Xcode 16's synchronized group: the
directory is the target member, so a new file compiles without editing
`project.yml`. Do not turn it into a file list.

## Verifying a change

Reading the code is not verification. Four things actually work:

**The layout parser has a cross-check against a live server.** It walks every
window tmux currently has and compares parsed geometry against `list-panes`.
Run it after touching `TmuxLayout.swift`:

```sh
swiftc -O -o /tmp/layoutcheck Attache/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
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
swiftc -O -o /tmp/replycheck Attache/Tmux/TerminalReply.swift Tools/ReplyCheck/main.swift
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
swiftc -O -o /tmp/screenreplaycheck Attache/Tmux/TmuxPaneSnapshot.swift \
  Attache/Tmux/TmuxScreenReplay.swift Tools/ScreenReplayCheck/main.swift
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
swiftc -O -o /tmp/renamestringcheck Attache/Tmux/TmuxRenameString.swift \
  Tools/RenameStringCheck/main.swift
/tmp/renamestringcheck
```

It splits every case at every byte boundary and again one byte per chunk,
because tmux cuts `%output` wherever its own buffer ends — including between the
`ESC` and the `k`.

**`TmuxTransport` has one, and it executes the quoting instead of eyeballing
it.** A remote command crosses two shells — ssh joins its command words with
spaces and hands the string to the remote login shell, and the embedded
terminal's `command` goes through a local `/bin/sh -c` first — and a session id
is `$N`, which every unquoted layer expands to nothing. The check renders each
command and runs it through a real `/bin/sh` with an `ssh` stand-in that does
what OpenSSH documents, comparing the argv that falls out the far end
byte-for-byte. `HostConfig` validation and `TmuxVersion` parsing ride along.
Run it after touching `TmuxTransport.swift`, `HostConfig.swift` or
`TmuxVersion.swift`:

```sh
swiftc -O -o /tmp/transportcheck Attache/Tmux/TmuxSocket.swift \
  Attache/Tmux/TmuxTransport.swift Attache/Tmux/HostConfig.swift \
  Attache/Tmux/TmuxVersion.swift Tools/TransportCheck/main.swift
/tmp/transportcheck
```

**The remote helper has one, and it runs the real script against the real
parser.** `RemoteHelperScript` is the stateless `sh` loop every remote feature
reads through; `RemoteHelper` is the frame parser that trusts nothing it did
not length-prefix. The check bootstraps the exact shipped script through a
local `/bin/sh` — sh is sh, ssh is only the pipe — and drives it with the
exact shipped client, including the byte-exactness cases a spliced transcript
or a wrong `git status` would come from.

It also owns the **failed-launch** case, which is not about framing at all: it
drives twenty `start()`/`stop()` cycles against an executable that does not
exist and counts this process's open descriptors on both sides. That is the
one path with no EOF in it — see the trap below — so it is the one path a
self-clearing reader cannot repair, and descriptors are the unit it fails in.
Confirm it still bites by putting the readers back before `run()`: measured
2026-08-23, 160 descriptors held after 20 attempts, 8 per attempt.

Run it after touching either file:

```sh
swiftc -O -o /tmp/helpercheck Attache/Tmux/TmuxLog.swift \
  Attache/Tmux/PipeRead.swift \
  Attache/Remote/RemoteHelperScript.swift Attache/Remote/RemoteHelper.swift \
  Attache/Remote/PosixChecksum.swift Attache/Status/GitStatus.swift \
  Tools/HelperCheck/main.swift
/tmp/helpercheck
```

**`ChromeTheme` has one, and it runs against all 485 schemes rather than a
fixture.** The chrome's colours are derived from whichever scheme the user
picked, so a rule that looks right on the two an agent has open can be wrong on
a hundred others — and wrong in a way nobody reports, because text that is
merely hard to read reads as a theme, not as a bug. That is how the rail's depth
stayed broken: `blend(background, toward: .black, by: 0.22)` scales the step by
how bright the background already is, so it removed 5 of 255 levels on a dark
scheme and 53 on a light one. Measured 2026-08-25 from a screenshot, the light
rail sampled (186,187,188) with the row numbers at 1.5:1 on it, against
9.9 / 6.8 / 4.6 for the same three roles on the dark scheme.

Four properties are under test and none can be stated about a single scheme: the
rail is never lighter than the panes (the "flip when there is no room" variant
reverses it on 56 dark schemes), the step is the same L* everywhere it fits, the
three text roles never swap order, and the contrast floors are actually reached
wherever the scheme has the headroom. It links the package products a normal
build already made, because reading the real catalog is the point:

```sh
swiftc -O -o /tmp/chromethemecheck -I /tmp/dd/Build/Products/Debug \
  -Xcc -I -Xcc /tmp/dd/Build/Products/Debug/include \
  Attache/Settings/ChromeTheme.swift Tools/ChromeThemeCheck/main.swift \
  /tmp/dd/Build/Products/Debug/{GhosttyTheme,GhosttyTerminal,GhosttyKit,MSDisplayLink}.o \
  /tmp/dd/Build/Products/Debug/libghostty.a
/tmp/chromethemecheck
```

Confirm it still bites the way `PipeReadCheck` is confirmed — by mutation, not
by reading it. Measured 2026-08-25: putting the old `blend(background, toward:
.black, by: 0.22)` back fails **484 of 485 schemes**, and setting both text
floors to 0 fails **96 assertions across 57 schemes**; unmutated it is
`485 schemes (398 dark, 87 light), all pass`, exit 0.

**`TerminalLinkTarget` has one, and it decides what a click opens on the user's
machine.** libghostty matches the link and draws the underline; this turns the
matched string into a file, a directory, a URL or nothing. The two directions
fail differently — refusing a real path is a click that does nothing, while
accepting the wrong string hands a run of screen text to the system opener,
which is why schemes are an allow-list rather than "anything with a colon".
The file system is injected, so every case runs with no disk and no screen:

```sh
swiftc -O -o /tmp/linktargetcheck Attache/UI/TerminalLinkTarget.swift \
  Tools/LinkTargetCheck/main.swift
/tmp/linktargetcheck
```

**`GhosttyTerminfo` has one, and what it decides is whether a pane comes up at
all.** libghostty tells the child it is `xterm-ghostty` and points `TERMINFO`
at whatever `GHOSTTY_RESOURCES_DIR` names — which is now this app's own
bundle, and used to be an inherited path inside *Ghostty.app*. Two rules are
under test and they fail differently. Pinning `xterm-256color` when the entry
was really there costs a few terminal capabilities; *not* pinning it when the
entry is gone is a blank content half with no explanation anywhere. And the
variable, once taken over, must name something inside this bundle or nothing
at all — a branch that lets the inherited value stand reinstates the whole
dependency on another application. The file system and the environment are both
injected, so those cases run with no disk and no variables of their own —
including the ones that model a `setenv` that quietly fails.

Its last part is the exception and touches the real disk on purpose. The
compiled entries in `Resources/terminfo` are **committed, not built**, so
editing the source without recompiling would change nothing at runtime and no
fixture could notice; that part runs `tic` on the source and compares byte for
byte against what is committed. It therefore has to be run **from the
repository root** (or given the root as `argv[1]`):

```sh
swiftc -O -o /tmp/terminfocheck Attache/UI/GhosttyTerminfo.swift \
  Tools/TerminfoCheck/main.swift
/tmp/terminfocheck
```

**`PipeRead` has one, and what it protects is a single line whose absence
costs whole cores.** `readUntilEOF` is how every pipe in this app is read, and
it exists rather than `readabilityHandler` because the raw API keeps firing
forever once the child exits — silently, with nothing on screen and nothing in
the log.

The check observes two things, and both are the invariant itself rather than a
proxy: the handler is **read back after EOF and must be nil**, which is the
cancellation (and which a handler that deadlocked before the assignment also
fails), and the **process's own CPU time across the settle window**, which is
the production symptom in the units it was reported in. Both are asserted in
*both* directions — the hand-written unfixed shape must leave the handler
installed and must burn a core — because a check that only exercises the fixed
path cannot tell "repaired" from "instrument broken".

The first version made exactly that mistake and it is worth knowing why, since
it looked complete: it counted deliveries, and `readUntilEOF` filters the empty
EOF callbacks before `onData`, so "no deliveries after the child exited" stayed
true with the self-clear **deleted**. Caught by an independent review, then
settled by mutation — remove the `readabilityHandler = nil` line and rebuild
the check against it. That is the way to confirm any change here still works:

```sh
sed 's|handle.readabilityHandler = nil|// gone|' Attache/Tmux/PipeRead.swift > /tmp/mutant.swift
swiftc -O -o /tmp/mut /tmp/mutant.swift Tools/PipeReadCheck/main.swift && /tmp/mut
```

Measured 2026-08-23: before, `11 cases, all pass`, exit 0. After, 10 of 29
cases fail and each names the burn — 0.303s to 0.309s of CPU per 0.3s window,
one full core.

**The premise that empty means EOF is measured here too, and it is the half
that would fail silently.** `readUntilEOF` turns "no bytes" into "stop reading,
forever" — so if a read could come back empty with the writer still open, this
is not a CPU bug traded for a smaller one, it is a pane losing the rest of its
output with nothing said anywhere. Three things hold it up and each is a case:
the descriptor is **blocking** (asked directly at three moments, since POSIX
only promises "0 means EOF" on a blocking fd and Foundation installs its
monitor lazily — a future version setting `O_NONBLOCK` would falsify the whole
file with no other symptom); a **signal delivered mid-read** does not surface
as empty, tested with `sigaction` and **no SA_RESTART**, because `signal(3)` on
BSD sets it and the kernel would otherwise restart the read for us — 19,383
signals across 300KB, nothing lost; and a **lull with the writer open** is not
mistaken for the end. Every reader in `Attache/` is on an anonymous `Pipe`, not
a pty — checked, and there is no `openpty`/`forkpty` anywhere in the Swift
sources; the pane pty belongs to libghostty and never reaches these handlers.

Unlike the other checks here it spawns real children and watches a real clock;
the margins are orders of magnitude wide, so scheduler noise cannot move it:

```sh
swiftc -O -o /tmp/pipereadcheck Attache/Tmux/PipeRead.swift \
  Tools/PipeReadCheck/main.swift
/tmp/pipereadcheck
```

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
`set frontmost of process "Attache" to true` in the *same* AppleScript as the
keystroke so nothing can get between them.

**Test against a throwaway tmux *server*, not a throwaway session, and reach it
with `-L` on every single command.** The user's real sessions have long-running
agents in them, and a session-level mistake is a server-level accident.

```sh
tmux -L attache-test -f /dev/null new-session -d -s probe   # create
tmux -L attache-test list-windows -a                        # inspect
tmux -L attache-test kill-server                            # clean up
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
- **A macOS material is not a pane of glass, and it is why the window's
  translucency is hand-rolled.** `NSVisualEffectView` is a frosted sheet with an
  opacity of its own that no tint painted over it can reduce — a window at 15%
  tint over one still barely shows the desktop — and its blur is fixed per
  material with no API to change it. `NSGlassEffectView`, macOS 26's own, tints
  the backdrop itself, so anything painted on top applies the colour twice.
  Both were offered as choices next to this app's own blur and both were
  removed on 2026-08-24: a blur radius the user can actually turn is what
  neither will give up, and three mechanisms meant every drawing site had to
  ask which one was live before it knew whether to paint. `git log` before that
  date is where they are if they are ever wanted again.
  The blur is the **window server's**, not `CALayer.backgroundFilters` —
  `WindowServerBlur` records why: a backdrop filter cannot reach under the
  panes' Metal layers, so it blurs the window's edges and not its middle.
- **The rail is painted twice and the panes once, and the second coat has to
  know it.** AppKit fills the whole window with the window's `backgroundColor`;
  `SessionSidebarView.draw` then puts the rail's fill on top of *that*. Two
  coats at alpha `a` leave `(1-a)²` of the desktop where one leaves `(1-a)`, so
  a rail painted at the panes' alpha squares what it lets through and the gap
  widens with the opacity slider instead of staying constant. Measured
  2026-08-24 at 67% window opacity: panes 33% of the backdrop through, rail
  11%. `AppSettings.railFillAlpha` is the corrected alpha — `extra/(1-a)` — and
  anything painting a *second* coat over the window's own must use it rather
  than the total it wants to reach.
  Two halves of one window can only be compared this way: solve each
  independently for the backdrop colour it implies and see which model makes
  them agree. Here one coat put them 2.5x apart and two coats 0.4% apart, which
  is what settled it. Do not compare the halves by eye or by a single reading —
  the backdrop is the user's wallpaper and it is not a constant.
- **libghostty claims ⌘ keys.** Its terminal view treats them as candidates for
  its own keybinds before the main menu is consulted. `TmuxTerminalView`
  overrides `performKeyEquivalent` to give the menu first refusal.
- **libghostty already matches file paths, and `mouse on` hides that
  completely.** Its default matcher has three branches — schemed URLs, absolute
  and `./ ../` paths, and bare relative paths like `src/config/url.zig` — and
  the comment on it in Ghostty's source reads "detect URLs and file paths in
  terminal output". None of it is visible here, because link detection is
  skipped *entirely* while the program in the terminal has mouse reporting on,
  and tmux runs with `mouse on`. ⌘-hover therefore does nothing at all and
  reads exactly like a feature that was never implemented. The one exception
  Ghostty allows is ⇧, and it then strips ⇧ back off before comparing against
  the configured ⌘ (`mouseModsWithCapture`) — so ⇧⌘ works out of the box and
  `TerminalLinkGesture` rewrites any other gesture into it. Two things follow.
  **Do not read the local ghostty checkout to decide what libghostty supports**:
  it is a different commit from the pinned submodule, and this was called
  unsupported on that basis before `strings` on the actual `libghostty.a`
  settled it. And **do not turn `link-url` off** to stop it competing with
  hand-written detection — that key deletes the whole default matcher, paths
  included. Measured 2026-07-31 against the linked binary.
- **The app used to get its `TERM` out of Ghostty.app, and the variable that
  did it is inherited — so do not let it be inherited again.** libghostty
  names the child `xterm-ghostty` and writes its `TERMINFO` from
  `GHOSTTY_RESOURCES_DIR`. That variable was never set by this app; it arrived
  from whatever shell launched it and named a path inside *Ghostty.app*, an
  unrelated application. libghostty checks nothing before choosing the name,
  so a Ghostty that had moved left every pane with a terminal nothing could
  look up: `tmux attach` answers `missing or unsuitable terminal` and exits,
  the rail keeps working from its own connection, and the app reads as alive
  with a blank content half. Measured 2026-08-09 with an isolated config and
  an isolated server: pointed at a directory that does not exist, **only the
  control client ever attached**.
  The description is vendored now (`Resources/xterm-ghostty.terminfo`, its
  compiled form in `Resources/terminfo`, both copied into the bundle as folder
  references) and `GhosttyTerminfo.adoptOwnResourcesAtLaunch` takes the
  variable over before the first surface exists.
  **`TERMINFO` has to be taken over in the same breath, and missing it is easy.**
  libghostty rewrites `TERMINFO` only for the surfaces *it* spawns; every other
  child of this app — the control-mode `tmux -C`, ssh, the git tool's program —
  gets it by plain inheritance. A first version of this change took only
  `GHOSTTY_RESOURCES_DIR`, and the live app's control client was still measured
  carrying `TERMINFO=/Applications/Ghostty.app/…`. The two are **cleared first
  and only then filled**, never overwritten in place, and each write is
  **read back**: `setenv` can fail, and a single failed write over the
  inherited pair leaves this bundle on one name and another application's on
  the other — a half-owned environment that reads as owned from either name
  alone, and that every child inherits. Clearing first makes the worst case
  "neither is set", which libghostty and ncurses both already handle.
  `Decision.unownedVariable` reports what the environment actually says rather
  than what was intended, and the surfaces pin `xterm-256color` when it is set. What is
  deliberately *not* scrubbed: `PATH`, `MANPATH`, `XDG_DATA_DIRS` and
  `GHOSTTY_BIN_DIR` still mention Ghostty on a machine that has it, because
  those are the user's own shell exports and rewriting them would change what
  their panes can run. Four measurements hold the rest up
  and none are guessable: `TERMINFO` is **written** from the variable rather
  than passed on (a dead resources dir plus a valid inherited `TERMINFO` still
  failed); the resources directory itself is **never opened** — `TERMINFO` is
  `<dir>/../terminfo` by string arithmetic, which is why the directory this
  app names holds only a README; an absent variable and a present-but-empty
  one both take libghostty's own `xterm-256color` branch; and the compiled
  entry this repository ships is byte-identical to Ghostty's, from the same
  pinned commit. The rule to keep: **no branch may fall back to the inherited
  value.** A missing bundled entry *unsets* the variable, because restoring
  Ghostty.app's path there would quietly reinstate the whole dependency, and
  only on the machines where something was already wrong.
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
  **That filter is not in the path any more.** It was on the write callback the
  pane renderer owned, and deleting the renderer on 2026-07-31 took its last
  call site with it: `TerminalReply.swift` and its check tool are still here and
  still correct, but nothing calls them. Everything libghostty writes now goes
  straight down the pty that `tmux attach` is reading.
- **Mouse input reaches tmux now, and the note that said otherwise was true of
  a version that no longer exists.** The comment at `rightMouseDown` recorded,
  on 2026-07-29, that neither a right-click nor a left click produced a single
  outbound byte — measured against the pane renderer, where the app sat in the
  middle. On the `tmux attach` surface it is the opposite: **clicking a window's
  name in tmux's own status line switches windows**, measured 2026-07-31 by
  clicking one and watching `#{window_id}` change from `@124` to `@101`.
  Two things follow, and both are load-bearing for `TerminalLinkGesture`.
  Any NSEvent this app synthesises and hands to libghostty is real input as far
  as the program in the pane is concerned — a fabricated mouse move on a
  modifier press would send motion the user never made to whatever is tracking
  the mouse. And a press-drag-release sequence has to be rewritten as a whole or
  not at all, because libghostty decides *per event* whether ⇧ keeps it local,
  so rewriting only the press hands tmux motion with no press under it.
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
- **tmux ≤ 3.5 octal-escapes control-mode reply lines; 3.6 does not.**
  Measured 2026-08-04 against 3.5a and 3.6a with the same command over a pipe:
  `list-windows` answered a literal four-character `\001` on 3.5a where 3.6a
  sent the raw byte — so the `\u{01}` field separators this app asks for never
  match, and the window list of a remote 3.5 server silently stays empty.
  Notifications (`%subscription-changed` included) carry raw bytes on *both*,
  so the decode belongs to reply blocks alone, and it is gated on the probed
  server version (`TmuxVersion.escapesControlModeReplies`), because a decode
  applied to a 3.6 reply would corrupt content that legitimately contains
  backslash-digit runs.
- **A `readabilityHandler` that ignores empty data never stops running.** A
  dispatch read source on a pipe is *permanently readable* once the write end
  closes: `read` returns zero bytes at once and keeps doing so. The obvious
  handler — `guard !data.isEmpty else { return }` — therefore does not go quiet
  when the child exits; it is re-entered as fast as the queue can run it. There
  is no error, no log line and nothing on screen. The only symptom is a warm
  machine. Measured 2026-08-23 against `/bin/echo`: **1,552,268 calls in the
  two seconds after the child exited.** The live app the same day, up fourteen
  days, was at **1313% CPU** — 18 of its 39 threads spinning, 16 of them from
  helper channels to the `mini` host that had died and been replaced in the
  ordinary way and 2 from a control client that exited on its own, two pipes
  each — with 83% of the whole machine in the kernel. Clearing the handler is
  what cancels the source, so `FileHandle.readUntilEOF` does it in one place
  and nothing else in `Attache/` may set `readabilityHandler` directly. Note
  what let it survive: all three sites looked correct, `stop()` on the control
  client *did* clear its stdout handler, and the case that leaks is the one
  where teardown is never reached at all.
- **A reader installed before `run()` is not covered by its own self-clear,
  because a launch that fails produces no EOF.** `readUntilEOF` repairs itself
  when the write end closes — and when `Process.run()` throws, *no child ever
  existed to close it*. This process is still holding the write ends open
  through the `Pipe`s, so the source never fires, never clears, and keeps the
  handle alive. In `RemoteHelper` the stdout closure also captured `child`
  strongly, closing `child` → `Pipe` → `FileHandle` → handler → `child`, with
  nothing left to break it: `process` is still nil on that path, so
  `tearDown`'s `process = nil` clears nothing. `channelFailed` then schedules
  another attempt. Measured 2026-08-23 by reverting the fix: **160 descriptors
  held after 20 failed launches, 8 per attempt** — at the retry floor of one
  per thirty seconds that is roughly 960 an hour, and it accelerates, because
  descriptor exhaustion is itself a reason `posix_spawn` fails. The rule now:
  **every pipe reader goes in after its `run()` succeeded, never before**, at
  all three sites. `RemoteHelper` also holds `child` weakly, since the capture
  is only ever used for the identity test in `consume` and a deallocated
  `Process` is by definition not the current channel. `SSHPreflight` retries
  the same way and leaked two an attempt; `TmuxControlClient` does not retry
  today — `TmuxSessionConnection.start` reports the failure and stops — so it
  was bounded, and would stop being bounded the moment issue #4 adds a retry.
  Found by an independent review, not by the check: the leak predates
  `readUntilEOF` and the CPU work did not touch it.
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

Open work lives in the [GitHub issues](https://github.com/XueshiQiao/Attache/issues).
TODO.md was migrated there and deleted on 2026-08-04; its full text — including
the record of everything already finished and how it was verified — is in git
history before that date.
