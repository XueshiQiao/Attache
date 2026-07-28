# TODO

Ordered roughly by what unblocks the most. Read [CLAUDE.md](CLAUDE.md) before
starting — several of these touch code with non-obvious constraints.

**[Section 4b](#4b--state-the-gui-reconstructs-instead-of-asking-tmux) is
done** — every item in the 2026-07-27 audit is fixed, most recently on
2026-07-28. What is left is section 1's four unverified settings behaviours,
section 2's two deliberate build differences, section 5's features, and section
6's never-reviewed subsystems. **Section 5's translucency is the largest thing
not started.**

Three things in 4b were fixed but *not* watched running, and they are the first
thing to check when someone is at the machine — see [the end of 4b](#not-seen-running).

---

## 1 · Settings — done

`TmuxGUI/Settings/` holds the store, the chrome theme, and the window.

Deliberately not done, and still worth doing:

- [ ] Ligature and fallback-font settings. Named as a follow-up from the
      start and nothing since has changed that.
- [ ] Nobody has *looked* at the settings window. Showing it calls
      `NSApp.activate`, which takes the focus of whoever is at the machine, so
      it was only ever built off screen — that proves it does not crash and
      nothing else. Four pages need eyes: Terminal, Appearance, Behaviour,
      About.
- [ ] Kill-on-close has never killed anything. Deliberately given no debug
      hook, on the grounds that nothing destructive should have an unattended
      path to it, which also means testing it needs a human and a click. Only
      the half that matters for safety is verified: an absent key reads
      `false`, so the default stays hide.
- [ ] A real light↔dark flip at the OS level. The same recompute was exercised
      through the explicit override, but the system-initiated trigger is
      untested — flipping it for real changes the whole desktop of whoever is
      using the machine.

How the font change was checked, since the two halves were measured in
different places and neither alone is the whole claim:

- Multi-pane, on a throwaway `-L` server: three split panes, sizes 14 → 18 →
  11 → 20 → 14 and again at the clamped maximum of 72pt, every pane's parsed
  layout matching `list-panes` matching the surface's resolved grid, plus
  three font families and two window resizes.
- Single-pane, on the real server the app is actually used against: the same
  agreement at 14 → 18 → 11 → 14, after a window resize, and stable across a
  poll.

Multi-pane against a real session with real programs in it has not been done.
That is the combination this project keeps finding bugs in.

---

## 2 · Generate the Xcode project from `project.yml` — done

`project.yml` is the project now; `TmuxGUI.xcodeproj` is gitignored and
`xcodegen generate` rebuilds it. Everything the hand-maintained pbxproj carried
came across: the "Normalize libghostty Framework" post-build script (its body
now lives in `Scripts/normalize-libghostty.sh`, which `project.yml` names by
path and XcodeGen inlines into the generated phase), `ENABLE_APP_SANDBOX = NO`,
the local package reference with all four of its products, and `TmuxGUI/` as a
synchronized folder rather than a file list. `TmuxGUIUITests` came across too —
an earlier draft of this section called it the sample's placeholder, which
stopped being true in 885633c. Checked by diffing `xcodebuild -showBuildSettings`
for Debug and Release against the old project, then building a fresh clone and
launching it.

The one test in `TmuxGUIUITests` is a launch smoke test: the app starts, gets a
window, and draws the session rail from live tmux state. It is in the scheme's
test action only, so a plain build does not build it. It has never been run
here, and running it is not free — it launches the app for real, which takes the
focus of whoever is at the machine and attaches to whatever tmux server is live.
Growing it into something that covers more than launch means giving it a
throwaway session on its own `-L` socket to drive.

Two things left deliberately different, noted here so they are not mistaken for
oversights:

- [ ] **The SwiftPM lock file is no longer in git.**
      `TmuxGUI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
      used to be committed with the project and pinned MSDisplayLink — the one
      transitive dependency, which `libghostty-spm`'s `Package.swift` takes as
      `from: "2.1.0"` and can therefore float across the whole 2.x range. It
      lives inside the now-gitignored `.xcodeproj`, so a fresh clone resolves it
      afresh. It resolved to the same 2.1.0 revision today, but nothing holds it
      there. Fixing it means un-ignoring that one path, which needs a chain of
      `!` rules through every parent directory.
- [ ] **Code coverage instrumentation is off now, and was silently on before.**
      `xcodebuild -showBuildSettings` on the old project reported
      `CLANG_COVERAGE_MAPPING = YES` when asked via `-scheme` and not when asked
      via `-target`, so it came from the old shared scheme, not from the
      project — which also explains the `default.profraw` the app kept dropping
      in the repo root. Its cost was never measured. If coverage is wanted it
      belongs in the scheme's test action on purpose.

(`LookInsideServer` was already removed — see section 3.)

---

## 3 · Make the UI inspectable by an agent — done

`TmuxGUI/Debug/` holds it. A debug-only HTTP endpoint on 127.0.0.1:47623,
off unless `TMUXGUI_INSPECT=1` or the Debug menu turns it on, serving the
view hierarchy (`/views` — including each layer's overhang, the field that
explains a correct-looking view rendering nothing) and the app's tmux state
(`/tmux`, shaped to diff against `list-windows`, plus `sessionControllers` for
the one thing that dump could not otherwise show: a controller the app is
holding for a session tmux no longer has). The settings work added write routes
so a font change can be driven without a pointer.

The closed-source inspector this replaces is gone for good: an agent could
not read it, which made it pure cost here.

---

## 4 · Known defects

**The active pane defect that used to head this list is fixed** — `TmuxWindow`
carries `activePaneID` from `#{pane_id}` in the window list, and a click reaches
tmux through `select-pane` rather than moving the ring locally. What it was an
instance *of* is the subject of the next section, which is the current work.

---

## 4b · State the GUI reconstructed instead of asking tmux — done

An audit on 2026-07-27, after three separate bugs turned out to be the same
mistake: the app inventing, inferring, or never setting something tmux has an
authoritative answer for. All nine items are fixed, the last seven on
2026-07-28. They are kept in worst-first order with what each one turned out to
be, because in six of the nine the mechanism was not what the bullet said and
the difference is the part worth reading.

Everything stated about tmux below was measured on **tmux 3.6a** against an
isolated server. Re-measure rather than trusting these notes.

### 4b.1 A zoomed pane is invisible to the app — done

tmux keeps two layouts per window and this app was reading the wrong one.
`#{window_layout}` is the **saved** arrangement, which zoom does not touch;
`#{window_visible_layout}` is what is on screen. `%layout-change` carries both —
`<window-id> <saved> <visible> <flags>` — and `TmuxNotification` kept the second
field and dropped the rest, so `TmuxSessionConnection.handle` compared a string
zoom cannot change against the one it already had, found them identical, and
returned before anything redrew.

`TmuxWindow` carries both now, and which one each caller wants turned out to
matter more than the bullet said:

- `visibleLayoutText` places the panes. That is the fix as written.
- `savedLayoutText` answers *which panes the window has*, and `paneIDs` reads it.
  This half was not in the plan and is not optional. A zoomed window's visible
  layout is a single-pane tree, so
  `SessionViewController.releaseSurfacesForDepartedPanes` — which gives up every
  surface whose pane is not in the session's pane set — would have destroyed the
  other panes' surfaces and their scrollback on every zoom, and rebuilt them from
  a fresh `capture-pane` on the way back out. Swapping the format string alone
  would have traded one defect for a quieter one.

Both update paths needed changing and only one was in the bullet: selecting a
window that was left zoomed emits **no `%layout-change` at all** — measured on
3.6a, only `%session-window-changed` — so `TmuxWindow.listFormat` asks for both
variables as well. An empty visible field falls back to the saved one, since tmux
expands a variable it does not have to nothing rather than failing.

Reproduced before fixing and verified after, with the app pointed at a scratch
server: `TMUX` unset, `TMUX_TMPDIR` set, and that server administered only
through `-S <socket path>`, with the inspector's own session list checked first
to prove the app was not attached to the user's. **Before:** tmux puts `%1` at
126x42 filling the window while the app goes on drawing it at 62x42 in the right
half — 64 columns of disagreement, with the shell's echo of a typed command
visibly scrambled on screen. **After**, in four situations — zoom, unzoom,
re-zoom onto a different pane, and attaching to a session that was *already*
zoomed — every pane the app reports matches `list-panes` exactly, the zoomed
surface resolves to a 126x42 grid, and the hidden panes' surfaces are still held,
detached from the view tree with their grids intact.

`Tools/LayoutCheck` had to be extended rather than left alone, because it was
about to start failing: it compares parsed geometry against `list-panes`, and
`list-panes` reports the zoomed size. It now checks the visible layout against
every pane and the saved layout against every pane *except* the zoomed one, where
disagreeing with `list-panes` is the correct answer; prints how many zoomed
windows it actually saw, so a run that never exercised the case cannot read as
though it had; and takes `-L`/`-S` arguments so that case can be reached without
zooming a pane on the user's own server. The pre-fix logic — same file with the
argument passthrough patched in, since it had none — reports exactly the two
disagreements on a server with two zoomed windows and nothing else.

It keeps empty fields when splitting the reply, which is not a detail: an older
tmux expands `#{window_visible_layout}` to nothing, dropping empties would shift
every field left, the field-count guard would skip that window, and the run would
print ✓ having checked nothing at all. Such windows are counted and reported as
skipped instead.

`#{window_zoomed_flag}` is deliberately not in the model. The two layouts
differing *is* the zoom, so the debug inspector derives `isZoomed` from them and
cannot print a flag that contradicts the geometry printed beside it.

Codex reviewed the diff and found no high-severity defect. Three of its four
findings were real and are fixed; the fourth is recorded below. The one worth
remembering is that `String.split` **drops empty subsequences by default**, which
bit the same change twice: an empty visible field in a `%layout-change` would
have slid the *flags* into `parts[2]`, so `*Z` would have been stored as a
window's layout — unparseable, and the app would have gone on drawing the
previous pane tree with nothing to show anything had gone wrong. The same
mistake in `Tools/LayoutCheck` was caught while writing it and missed here.
`TmuxNotification` now keeps empty fields and checks the leading two for
emptiness, since dropping empties is what used to do that for free.
`Tools/LayoutCheck` also stopped asking `list-windows` and then `list-panes` per
window: those are two snapshots, and a pane zooming between them made the flag,
the layouts and the geometry describe different moments — a false failure in the
one tool that exists to be believed. Window-scoped variables resolve inside
`list-panes` (verified on 3.6a), so a single `list-panes -a` now carries all of
it. Seven parse cases covering both live forms, the pre-2.2 two-field form, the
empty-field forms and the degenerate ones are in
`scratchpad/notifcheck.swift`-shaped throwaway form only — if `%layout-change`
parsing is touched again, that table is worth rebuilding first.

A second review pass over those fixes found nothing wrong with the notification
parsing and three things wrong with the checker, all of them the same shape: it
could report success without having checked anything. `tmux()` threw away both
the exit status and stderr, so pointing the tool at a socket that does not exist
gave empty output, zero windows, an empty failure list and `✓ every pane agrees`
on exit 0 — verified, and it is how an earlier run in this very session was
briefly misread. A failed query is now fatal and prints tmux's own error. Rows
the parser cannot read, windows skipped for want of `#{window_visible_layout}`,
and a run that checked no window at all are all **failures** now rather than
notes printed above a tick: a skip line followed by ✓ is a contradiction the
reader resolves in favour of the ✓, and this file is only worth having if its ✓
can be believed.

**Not fixed, and pre-existing:** a layout that is non-empty but unparseable makes
`syncWithModel` return before `gridView.setContent`, so the old window's panes
stay on screen while the title band moves on. That was equally true of the single
layout string this change replaced, no path in the fixed code can now reach it,
and deciding what to show instead — a blank content half? — is a different
question from this one.

**Found while verifying, and left for section 5: nothing in the GUI can zoom a
pane.** The audit assumed `prefix z` typed into the app reaches tmux. It does
not. Keys are forwarded with `send-keys -t %id`, which writes bytes to the pane's
pty, and tmux applies its prefix only to keys read from an attached client.
Measured both directions on 3.6a: `send-keys -H 02 7a` (C-b, then z) leaves a
zoomed window zoomed and an unzoomed one unzoomed. Zoom therefore only ever
arrives from outside — `tmux resize-pane -Z` run inside a pane, another terminal
on the same session, or a session that was already zoomed when the app attached.
All three are handled; none of them is the one the bullet described.

### 4b.1b The app never noticed tmux ignoring its size — done

Reported 2026-07-28 with a screenshot: two panes drawn in the top-left corner of
a much larger window, the rest dead space. The session had an ordinary terminal
attached to it as well, at a different size.

The mechanism is not the one the bullet for this would have guessed, and it is
worth stating exactly, because "take the size back" was already written and
already worked. `reportGrid` sends `refresh-client -C` **once per distinct size**
— it deduplicates. If tmux declines, because `window-size latest` has made some
other client the most recent, then **tmux sends nothing at all**: the layout did
not change, so there is no `%layout-change`. And `reclaimWindowSizeIfTaken` was
reachable only from `syncWithModel`, which runs on notifications. So the app
asked once, was ignored, was never told it had been ignored, and never asked
again. Deadlock, and it holds for as long as the app stays open.

Measured on the real server: the app reported `refresh-client -C 126x42`, tmux
kept the window at 278x74, and `taking it back` appeared **zero** times in the
log — the recovery path never ran once. Bringing the app to the front then fixed
it in one attempt.

So the missing input was never a tmux notification. It was *the user coming back
to the window*, which tmux cannot know about. `MainViewController` now observes
`didBecomeActive` and `didBecomeKey`, coalesces them (one click delivers both,
and acting on each sent two `switch-client` + `refresh-client` pairs 13ms apart),
and reclaims from the state that has settled rather than from the notification.

**The second half came from the report and matters more than the first.** Taking
the size back on every `%layout-change` regardless of focus is a fight, not a
fix: the user resizes in their terminal, tmux announces it, a backgrounded app
grabs it back, and the layout visibly jumps back and forth. Eight
notification-driven reclaims were observed in one short run. Two clients of
different sizes cannot both be satisfied — tmux gives a window one size — so the
rule is now that this app only ever claims the size while it is the **key
window**. Backgrounded it draws what tmux says even when that leaves dead space,
because dead space is honest and a fight is not. Verified on the real server:
eight rounds of activity in the terminal while the app was hidden produced **0**
reclaims, and returning to the app produced exactly **1**.

`window-size manual` and `smallest` are still bounded per notification, but a
return now resets that counter — a person switching back is a new intent, not the
previous argument continuing. Codex flagged that repeated focus changes can
therefore keep asking; that is accepted, because each ask costs two commands and
requires a deliberate human action, and the alternative silences the one moment
the app is entitled to the size.

### 4b.2 A session rename tore down a healthy session — done

Sessions were keyed by name everywhere — `TmuxServer.connections`,
`MainViewController.controllers`, the rail's rows, its expanded set, its rename
editor — and `%session-renamed` was parsed into `.other` and dropped. Both
stages of the bullet were real and reproduced against a scratch server: the
rail kept the old name indefinitely, and the next `list-sessions` for any
unrelated reason (creating a third session was enough) printed `sessions no
longer on the server, dropping connections: alpha`, sent `detach-client`, and
destroyed the controller with its GPU surfaces, primed scrollback and hidden set
before rebuilding under the new name.

The identity is `$N` now, from `list-sessions -F '#{session_id}
#{session_name}'`. Two things the bullet did not anticipate:

- **The id is known before the attach**, so `TmuxControlClient` attaches with
  `-t $0` rather than `-t '=name'` — verified on 3.6a that a session id is
  accepted wherever a session target is. That also closes the window in which
  any terminal can rename a session between it being listed and being attached
  to, and it removed the several "no session id yet" guards that could silently
  swallow a command.
- **`%session-renamed` is broadcast to every control client on the server**,
  not only to those attached to the renamed session — measured, a client
  attached to `$0` is told about `$1`. Applied without checking the id, every
  connection would end up named after whichever session was renamed last. Same
  shape as the `%client-session-changed` trap already in CLAUDE.md.

The rail carries ids too. Its `expandedSessions` had the same defect in
miniature: keyed by name and pruned against the entries, a rename closed the
session's window list.

### 4b.3 A replayed screen restored text and colour and nothing else — done

Eighteen mode variables ride along in the `display-message` the capture already
makes. All or nothing: a half-read reply would put the surface in some *other*
terminal's modes, so the field count is checked and an unparseable reply falls
back to exactly the old behaviour.

The emit order is the substance, and three of the four orderings were measured
rather than reasoned:

- **`cursor_y` is absolute even under origin mode.** With a scroll region of
  rows 4-9 and DECOM on, putting the cursor at region-relative row 2 makes tmux
  report row 4. `CUP` under DECOM counts from the top of the region, so tmux's
  number sent straight through is `scroll_region_upper` rows of silent drift on
  exactly the programs that use a region.
- **DECSTBM and DECOM both home the cursor**, so both precede the cursor.
- **The alternate screen is entered between the history and the rows** —
  measured, `capture-pane -S -N -E -1` returns the *primary* screen's scrollback
  while the plain capture returns the alternate screen. The switch is stated in
  both directions on a repaint, because a program that has exited needs
  `?1049l` as much as one that started needs `?1049h`.
- **The cursor shape mapping was measured**: DECSCUSR 0 reads back as
  `default`, 1/2 `block`, 3/4 `underline`, 5/6 `bar`, with the odd values
  setting `cursor_blinking`. `CSI ?12h` sets `cursor_blinking` alone, which
  DECSCUSR cannot express, so blink is carried separately.

`pane_in_mode`/`pane_mode` and `%pane-mode-changed` are still not handled — see
copy mode in section 5, which is where that belongs.

### 4b.4 The first paint parked the cursor wrongly — done

The premise the old comment rested on was escapable exactly as the bullet said,
and the fix is one capture more rather than one clever trick. `capture-pane` is
asked twice: `-S -N -E -1` for the history and a plain capture for the screen.
Measured — a 10-row pane with 52 rows of history answers the first with 52 rows
ending `L51` and the second with 10 rows starting `L52`. No overlap, no gap, so
after the history has scrolled through the viewport, viewport row 0 is screen
row 0 and `CUP` means what tmux said.

The screen's rows stopped being trimmed for the same reason: every row has to be
written or the cursor row is counted from the wrong place. Trimming survives for
the one case that still needs it — a pane tmux would not give a cursor for.

### 4b.5 Activity dots updated only when something unrelated poked the model — done

`refresh-client -B 'tmuxgui-activity:@*:#{window_activity_flag}'` after the
attach, plus a `%subscription-changed` handler. Reproduced and verified: with
the background window's flag cleared first, one `printf` into it and nothing
else at all left the pre-fix app saying `False` three seconds later and the
fixed one saying `True`.

Two things the bullet did not say. **Subscribing produces one
`%subscription-changed` per window immediately**, so the dots are right from the
attach rather than after the first change. And **it depends on the user's
`monitor-activity`, which tmux leaves off by default** — measured, with it off
the flag never leaves 0 and there is nothing to subscribe to. That is not this
app's to override: it is the same option that decides whether a plain
`tmux attach` shows the `#` in its status line.

### 4b.6 The first paint could print the same output twice — done

Real, and reproduced: showing a session whose pane had printed six lines while
off screen drew `sh-3.2$ sh-3.2$ for i in …` where tmux has one prompt — the
router's buffer and the snapshot's first row on one line.

**Picking one of the two sources, which is what the bullet proposed and what the
router's own doc said the return value was for, does not work.** The choice has
to be made when the snapshot comes back, and by then it is wrong either way:
showing a session sends `refresh-client -C`, tmux reflows, and the pane writes.
Measured — every first paint took the "it wrote while the capture was in flight"
branch, so no pane would ever have been given its scrollback.

So both go out and the snapshot *erases* first: home, `CSI 2 J`, and on a first
paint `CSI 3 J` for the saved lines. The buffer is replaced rather than added
to, which makes the second copy impossible instead of unlikely. `CSI 3 J` is
asked for and not relied on — if this libghostty ignores it the residue is
scrollback, never the screen.

### 4b.7 Bracketed paste was decided by a reconstructed state — done

`paste-buffer -p` is authoritative, exactly as the bullet said. Measured with
`cat -v`: mode off and `-p` gives the bare text, mode on and `-p` gives
`^[[200~…^[[201~`, mode on without `-p` gives bare.

**The text goes through a file, and that is the design rather than a detail.**
tmux's parser expands `$VAR` inside a double-quoted argument — measured,
`set-buffer -b probe "…$HOME…"` stores `/Users/joey` — and a single-quoted
argument is literal but can carry neither a newline nor a single quote.
Clipboard text is arbitrary and usually multi-line, so no quoting of it is both
correct and safe. `load-buffer` takes a path, so the only thing interpolated is
a path this app chose — the same reasoning as targeting tmux by id. The file is
owner-only and deleted the moment tmux answers; `-d` drops the buffer so the
user's own paste buffers are untouched.

Intercepted at the Edit menu rather than by overriding `paste(_:)`, which is
where it belongs: libghostty declares that method `internal`, so
`TmuxTerminalView` cannot override it. Everything that is not a pane is
forwarded back down the responder chain.

### 4b.8 ⌘1-9 counted slots while the rail showed tmux indices — done

They address `window_index` now, the way tmux's own `prefix 0-9` does. ⌘0 is
new, for the same reason `prefix 0` exists: a `base-index 0` session has a
window 0 and it was the one row with no shortcut. A hidden window is not
selected — its row is not in the rail, so its number addresses nothing, and
selecting it would bring it back because `syncWithModel` restores whatever tmux
makes active.

Worth recording because it changes how bad this was: with `base-index 1`, which
is what this machine's `~/.tmux.conf` sets, the numbers lined up by coincidence
until a window was hidden. The bullet's example assumed tmux's default of 0.

### Not seen running

Three of the seven were fixed and verified only as far as tmux, because both
displays on this machine were asleep for the whole session and there is no way
to wake one from an agent's shell — `screencapture` answers `could not create
image from display`, the inspector's own compositing returns plain white, and
neither `cliclick` nor `osascript … System Events` can synthesise a keystroke
without an Accessibility grant. What a person should check first:

- [ ] **⌘4** selects the row the rail labels **4**, and ⌘0 reaches window 0 on a
      `base-index 0` session. Only the lookup is tested; nobody has watched a
      keypress arrive.
- [ ] **⌘V into a pane** pastes, and a multi-line paste into `vim` after
      switching windows does *not* staircase. The tmux exchange is verified end
      to end; the menu interception and the file write are not.
- [ ] **Scroll a pane up on arriving at a session.** The history should be
      there, once, with no duplicate of the last screenful — that is the half of
      4b.4 and 4b.6 that lives in libghostty's own buffer, which nothing outside
      the app can read.
- [ ] While there: a pane running `less` or `vim` should take the **scroll
      wheel** after a window switch, and `htop` should not gain a stray cursor.
      That is 4b.3 arriving, and it is the item with the most sequences and the
      least observation behind it.

### Checked and found fine

`%client-session-changed` ignored on purpose and documented. The repaint timing
constants — each stands in for a signal tmux genuinely does not send, and each
is bounded with the honest failure direction. `freeIndexAtEnd`'s margin, the
placeholder cell size, the metrics window, `scrollbackPrimeLines` as a ceiling
tmux clamps. `capture-pane` on an alternate-screen pane returns primary history
plus the alternate screen as text, so the prime's *content* is complete — only
the modes in 4b.3 were missing, and they are supplied now.

The probe's modal is gone too — it was fixed by the settings work rather than
here, and the bullet outlived it. The report renders inline on the About page;
the only `runModal` calls left are the fatal "no tmux" startup alert and the
confirmation before killing a window, and both should stay.

Nine are fixed. None of them was quite what its bullet said, so what each turned
out to be, most recent first:

**A session shown for the first time could stay blank**, and the bullet had the
cause wrong. It blamed tmux for sending nothing when the requested size already
matched. Measured on tmux 3.6a by driving `tmux -C attach` over a pipe:
`refresh-client -C` emits a `%layout-change` **every** time, including when the
size asked for is the size the window already has. What swallows it is this app,
and correctly — `TmuxSessionConnection.handle` drops a `%layout-change` whose
layout text is unchanged, because nothing changed. So the symptom was real and
its stated mechanism was not, and the fix is the same either way:
`MainViewController.show` renders the model itself, right after the controller's
view goes into the hierarchy, instead of waiting to be told something it has
already been told. After `content.show` and not in the controller's
`viewDidLoad`, because the sync also hands first responder to the focused pane
and at `viewDidLoad` the view has no window yet. Reproduced before fixing, on a
session whose window `resize-window` had put on `window-size manual` — tmux will
not resize such a window for anybody, so no layout string ever changes: the
inspector reported that session on screen with zero surfaces and no layout for
as long as it was left there, and after the fix reports one surface and tmux's
own 120x35 grid *in the same main-actor turn as the show*. Reaching it needs no
unusual option, either — a `window-size smallest` session with a smaller client
attached elsewhere does it too.

**A vanished session left its controller behind**, and the inspector could not
see that, which is why the fix came with a field rather than only a fix.
`/tmux`'s session list is generated from what tmux currently has, so a
controller for a session that is gone was absent from the dump instead of
flagged in it; `TmuxReport.sessionControllers` now lists what
`MainViewController` is actually holding, and a name in it that is missing from
`sessions` is the leak. What the leak held: the controller's GPU surfaces, and
its panes still registered to a router whose connection had been stopped. It
also aimed a foot-gun at any new session created with an old one's name, since
`show` looks controllers up by name and would have handed back the stale one
pointing at the dead connection. `discardControllersForVanishedSessions` runs
from `refreshSidebar`, on the same reconcile that drops the connection. Not
hypothetical: this machine has a `_lazygit` popup session that comes and goes,
and its controller was observed being dropped mid-run.

That covered every case but the last one, and Codex found the gap: killing the
*last* session takes the whole tmux server with it, and `refreshSessions` used
to `return` on an empty `list-sessions` before reaching any of the cleanup — so
`onChange` never fired, the dead connection and its controller stayed, and there
was no route out, because every trigger that would re-ask arrives *on* a
connection. The empty answer now reconciles like any other, which meant teaching
`TmuxControlClient.listSessions` to distinguish "tmux would not spawn" (`nil`,
change nothing) from "tmux answered and listed nothing" (`[]`, drop everything).
Two consequences worth knowing about. The app has an empty state now — no rail
rows, no content — where before it kept a frozen session on screen; and because
nothing can notify an app with no connections, that state re-asks once a second
until a server exists. Verified against a scratch tmux server the app was pointed
at with `TMUX_TMPDIR` and administered exclusively through `-S <socket path>`:
killing the only session emptied the app (`sessions=[]`, `sessionControllers=[]`,
`shownSession` absent) and left it alive, and creating a session on that server
again brought the app back on its own within one tick, attached and rendering,
with nothing clicked. `stop()` sets a flag the re-ask checks, because control
clients report their exit about a millisecond *after* teardown finishes and each
of those exits schedules a refresh — today the process dies before the main
queue turns again, which is not a guarantee to lean on once something waits a
second.

**A superseded repaint batch is merged into the next one** rather than thrown
away. Measured with the same script before and after, on a scratch session with
two windows: resize the app window (which reflows the active window's pane, so
that pane is batch A), then select the other window within the 150ms coalescing
delay (batch B, a pane set that does not include A's). Before: the switch landed
134ms after the resize and pane A received **no `capture-pane` at all**, ever —
`paintedFrames` had been advanced for it on the way in, so no later sync could
see it as changed, and it kept text wrapped for its old width until its geometry
happened to change again. After: the switch landed 37ms after the resize and both
panes were captured 1ms apart, i.e. by one drain of the merged set. Panes now
accumulate in `pendingRepaints`, and a pane already waiting takes the newer
delivery-count baseline, because the question the snapshot asks is whether the
pane has been quiet since its *latest* geometry change.

**`TmuxMetrics.Snapshot.report` is gone** rather than made honest. Nothing called
it — the sidebar footer takes `titleSummary`, the probe formats its own
comparison — and what it printed was the problem: the arrival gap statistics laid
out as a general-purpose readout, which is exactly the reading `titleSummary`
exists to refuse. The two lifetime-rate properties it was the only caller of went
with it. The counters they divided stay, because the probe reads them.

The five from before:

**Teardown ran twice per shown session.** `TmuxServer` owns every connection
and is now the only thing that stops one; `SessionViewController.stop()` became
`releaseSurfaces()`, which gives up its surfaces and unregisters its panes and
nothing else. The log is the oracle: a shutdown that used to print two
`detach-client` lines for the session that had been on screen now prints one
line per session, five sessions, five lines, with all five having been
displayed during the run.

**The stall figure** was dropped from the footer rather than gated. A gap
between chunks is only a stall if the pane had something to send, and nothing
on this side of the pipe can tell that apart from a program with nothing to
print — so gating on recent activity still reports a pane's own silence as
latency. The footer now carries byte rates over the last two seconds, and the
word `idle` when nothing is arriving. The gap statistics are still measured and
still mean something in the one place that constructs a source emitting at a
known rate: the A/B probe.

**`capture-pane` replies** are accumulated as `[Data]`. `runBytes` is the byte
path; `run` decodes on top of it for `list-windows` and the probe, which ask
tmux for its own format output. Worth recording what tmux 3.6a actually does,
because it explains why the defect had never been seen: a reply block is
*unescaped*, so it can carry any byte — verified by driving `tmux -C attach`
over a pipe and watching `show-buffer` return `41 e9 ff 80 42` inside a
`%begin`/`%end` block — but tmux replaces invalid UTF-8 with U+FFFD in its own
grid before `capture-pane` can see it, and escapes format output as `\351`. The
transport was unsafe and the two commands this app sends happened not to
exercise it.

**A fifth, found while fixing the fourth and belonging to the same subsystem:
`isBlockTerminator` matched reply *content*.** It accepted any line beginning
`%end ` or `%error ` as the end of a reply block — including a line of the pane
screen the block was carrying. The trigger is this project's own subject matter,
not hostile input: a pane showing a captured control mode transcript has such
lines on it. Measured against the pre-fix code on a scratch `-L` server, with a
pane displaying `%end 999999 999999 0`: the `capture-pane` reply came back
**truncated to zero lines**, and every command after it received the *previous*
command's reply — the completion FIFO shifted by one and stayed shifted. Silent,
and permanent for that connection. The fix is that a terminator must carry the
number tmux stamped on the matching `%begin`; that number is a per-server command
counter a pane's contents cannot know. The same test passes on the fixed code
with the line carried through as content, and a mismatch is logged rather than
ignored, so a future tmux that stopped matching the numbers would be diagnosable
instead of looking like a hang.

**Repaint after resize** waits for the pane instead of painting over it. A pane
that has written since the geometry changed has redrawn itself, so its snapshot
is deferred 400ms and retried up to four times; a pane that never falls quiet is
left to its own redraw. Skipping outright was the first version of this and it
was wrong — one chunk is not proof the program repainted the whole viewport, so
a pane that echoed a prompt and then went quiet would have kept its old wrapping
until its next resize. The final check and the hand-off now happen together
inside `TmuxOutputRouter`, under the lock the reader queue takes: as two steps
there was still a window for live output to be enqueued between them and the
snapshot to land on top of it.

---

## 5 · Features not started

- [ ] **Translucency, the way Ghostty does it.** Asked for 2026-07-27, after
      the window tabs moved into the rail: the app should read as one piece of
      frosted glass rather than as flat fills.

      Half of it already exists and is worth reading before starting.
      `SessionSidebarView.draw` paints `ChromeTheme.background` at **0.55
      alpha** over the `NSVisualEffectView` the sidebar split view item
      supplies, which is what makes the rail sample the desktop behind the
      window while still taking its colour from the terminal scheme. The pane
      side is the opposite: `PaneGridView` fills `ChromeTheme.background`
      opaque, the window is `isOpaque = true`, and the surfaces are built with
      `withBackgroundOpacity(0)` so the grid's fill is what shows through
      between glyphs.

      So the work is on the pane side, and the order matters:

      1. `window.isOpaque = false` plus a background colour with alpha, or an
         `NSVisualEffectView` behind the content half.
      2. A user setting for the opacity, and one for whether the blur follows
         the window or the desktop (`.behindWindow` vs `.withinWindow`).
      3. Measure it. Ghostty's own docs warn that background blur costs real
         GPU time; this app already has a throughput probe, and the question
         "does 19 MB/s still arrive on time through a blurred window" is
         exactly the kind it answers.

      Two traps are already known and both will bite here. `PaneGridView.draw`
      must keep matching `window.backgroundColor`, because on macOS 26 that
      view's backing layer runs 66pt past its bounds and paints the *window's*
      colour in the overhang — with translucency the two being different stops
      being invisible. And `ChromeTheme` derives every colour from the terminal
      scheme's foreground/background pair on the assumption they are opaque; a
      contrast floor computed against a colour that is now translucent is no
      longer a contrast floor.

- [ ] **Write down what the layout has to be renegotiated for, in one place.**
      Low priority, asked for 2026-07-28, and the reasoning is worth keeping
      because it came from the right observation: this app already *is* a
      unidirectional data flow in the React sense — tmux is the store, a tmux
      command is the action, a control-mode notification is the subscription,
      `syncWithModel` is the render, and only two values are authored locally.
      What it lacks is React's dependency list. Nothing anywhere states which
      events make the grid need renegotiating with tmux, so an input can simply
      be missing and nothing points at the hole.

      4b.1b was exactly that: tmux notifications, window resize, font change and
      session switch were all wired up, and *the user returning to the app* was
      not. It cost a screenshot and a wrong first diagnosis to find.

      The work is to collect those triggers into one place with a line each on
      why it is there — not to add an abstraction layer. A layer holding state
      between the app and tmux would be a second place that can disagree with
      tmux, which is the mistake all of section 4b is made of; the reconciling is
      already done twice over (tmux only announces real changes,
      `PaneGridView.setContent` already reuses surfaces); and what gets rendered
      is a GPU terminal surface whose rebuild costs the pane's scrollback, so the
      reuse rules are nothing like a DOM's. See 4b.5 for the part that genuinely
      is more React-shaped: subscribing to specific tmux format variables with
      `refresh-client -B` instead of re-reading the whole window list.

- [ ] **Search** within a pane's scrollback. libghostty has
      `TerminalSurfaceSearchDelegate`; the buffer is already populated.
- [ ] **Copy mode.** tmux has its own; decide whether to drive `copy-mode` or
      use libghostty's selection. Driving tmux keeps the two views consistent.
- [ ] **Multiple app windows.** `MainViewController` assumes one. `TmuxServer`
      would need to be shared rather than owned.
- [ ] **Pane splitting from the GUI.** `split-window` is trivial to send; the
      question is where the affordance lives.
- [ ] **Zooming from the GUI**, same question and the same answer for the
      command — `resize-pane -Z -t %id`. Worth listing separately because the
      gap is easy to miss: `prefix z` typed into the app does *not* do it, since
      keys go out as `send-keys` to the pane's pty and tmux reads its prefix only
      from an attached client. Measured on 3.6a; see 4b.1. The app renders zoom
      correctly, it just cannot start one.
- [ ] **ssh / remote tmux.** The control client spawns a local `tmux`. Running
      it as `ssh host tmux -C attach` should mostly work, but throughput over a
      network has not been measured and the probe exists to answer exactly that.

---

## 6 · Not yet reviewed

The whole codebase was written in one pass with verification-by-running but no
independent review. A review pass should look hardest at:

- Threading in `TmuxControlClient` and `TmuxOutputRouter` — the reader queue
  touches state the main thread also reads, guarded by `NSLock`.
- The `%begin`/`%end` reply pairing. It is a FIFO of completions, gated on the
  attach handshake so tmux's own unsolicited block cannot desync it, but it has
  not been tested against a command that errors mid-stream.
- Lifetime of the closures wired between surfaces, connections and views.
