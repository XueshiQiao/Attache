# TODO

Ordered roughly by what unblocks the most. Read [CLAUDE.md](CLAUDE.md) before
starting — several of these touch code with non-obvious constraints.

**Start at [section 4b](#4b--state-the-gui-reconstructs-instead-of-asking-tmux),
item 4b.2.** That section is the current work and its items are ordered; it is
written to be picked up cold, with the tmux facts already measured. Nothing else
in this file is in front of it. (4b.1 is done — its entry is kept in place so the
worst-first ordering still reads.)

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

## 4b · State the GUI reconstructs instead of asking tmux

An audit on 2026-07-27, after three separate bugs turned out to be the same
mistake. Every item here is the app inventing, inferring, or simply never
setting something tmux has an authoritative answer for. **Ordered worst first —
take them in this order.**

Everything stated about tmux below was measured on **tmux 3.6a** against an
isolated `-L` server. Everything about the app is from reading the code. When a
fix is written, re-measure rather than trusting these notes.

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

### 4b.2 A session rename tears down a healthy session

- [ ] **Sessions are keyed by name everywhere, and `%session-renamed` is
      received and thrown away.** Filed as issue #1; this is the fuller reading.

      Stage one is cosmetic: rename a session — in the GUI's own editor or from
      any terminal — and the rail, the title band and the status line keep the
      old name indefinitely. The GUI's own rename appears to do nothing.

      Stage two is not. The next time `refreshSessions` runs for any unrelated
      reason, the old name is missing from `list-sessions`, so `TmuxServer`
      **stops the live connection and drops it** and
      `MainViewController.discardControllersForVanishedSessions` destroys the
      controller — GPU surfaces, primed scrollback and the hidden-window set all
      gone — then rebuilds from scratch under the new name. A rename becomes a
      delayed teardown of a session that was working.

      Measured: renaming sends exactly `%session-renamed $0 renamed` and **no**
      `%sessions-changed`, so nothing the app handles triggers a re-list.

      Fix: key `TmuxServer.connections` and `MainViewController.controllers` by
      `$N`; handle `%session-renamed` by updating a now-mutable name. The
      starting point already exists and is dead code: `TmuxSessionInfo` in
      `TmuxModel.swift` fetches `#{session_id}` and nothing parses it. Attaching
      can stay by `=name`, since the id arrives moments later on
      `%session-changed`.

### 4b.3 A replayed screen restores text and colour and nothing else

- [ ] **The snapshot replay reconstructs every terminal mode as "default".**
      `SessionViewController.replayPayload` sends home, erase, the rows, and now
      a cursor position. A terminal is more than that, and the app attaches to
      sessions whose programs set their modes long ago.

      Measured live with `less --mouse` in a pane: `alt=1 cursor=1 wrap=1
      insert=0 kpcursor=1 kp=1 origin=0 mouse_any=1 mouse_sgr=1 sru=0 srl=23`.
      None of it survives a repaint. Each of these is a format variable that
      exists on 3.6a and can ride along in the `display-message` round trip
      `capturePane` already makes — one format string, no extra commands:

      | Lost | tmux variable | Emit | What breaks today |
      |---|---|---|---|
      | Mouse tracking | `mouse_standard_flag`, `mouse_button_flag`, `mouse_all_flag`, `mouse_sgr_flag`, `mouse_utf8_flag` | DECSET 1000/1002/1003/1006/1005 | the wheel over a vim or less pane scrolls libghostty's own buffer instead of the program |
      | Alternate screen | `alternate_on` | `CSI ?1049h` | quitting vim "restores" a primary screen libghostty never saved |
      | Cursor visibility | `cursor_flag` | `CSI ?25h/l` | htop gets a cursor painted on its status area after every repaint |
      | Scroll region | `scroll_region_upper`, `scroll_region_lower` | DECSTBM, **before** the cursor restore, since it homes the cursor | a program scrolling inside a region wrecks the screen after a repaint |
      | Application cursor keys | `keypad_cursor_flag` | `CSI ?1h/l` | changes what libghostty sends for arrow keys |
      | Application keypad | `keypad_flag` | `ESC =` / `ESC >` | same, for the keypad |
      | Cursor shape and blink | `cursor_shape`, `cursor_blinking`, `cursor_very_visible` | DECSCUSR | cosmetic |
      | Wrap / origin / insert | `wrap_flag`, `origin_flag`, `insert_flag` | `CSI ?7`, `CSI ?6`, `CSI 4` | rare, but silently wrong |
      | Copy mode | `pane_in_mode`, `pane_mode`, and `%pane-mode-changed` fires on both enter and exit and is currently ignored | — | a replay cannot render copy mode, but the app could at least know |

      Note `cursor_x`/`cursor_y` keep reporting the *underlying* screen while a
      pane is in copy mode, so today's replay is at least self-consistent there.

### 4b.4 The first paint of a pane still parks the cursor wrongly

- [ ] **The repaint path was fixed; the prime path was not.** The first time a
      pane is shown — the first thing anyone sees on launch — the cursor lands
      at the end of the bottom-most line with anything on it. For a session full
      of running TUIs that is their status bars, app-wide, every launch.

      The comment at `replayPayload` says the cursor cannot be restored there
      because the prime replays scrollback that scrolled off the top, so tmux's
      row number has nothing to be relative to. **That premise is escapable:**
      `capture-pane -S - -E -1` returns history *only* — measured, 32 lines,
      ending exactly where the visible screen begins. Replay history, then the
      visible screen with the same erase + rows + cursor restore the repaint
      path uses, and the correspondence exists.

### 4b.5 Activity dots update only when something unrelated pokes the model

- [ ] **The dot is stale exactly when it matters.** Output arriving in a
      background window produces **only `%output`** on the control stream — no
      structural notification — while `window_activity_flag` flips server-side.
      The dot therefore appears whenever the next unrelated notification happens
      to arrive, which for a quiet session is never. The case it fails is the
      one it exists for: you are in session A, the agent in session B finishes
      and goes quiet.

      Fix, measured working on 3.6a: control-mode format subscriptions.
      `refresh-client -B 'actwatch:@*:#{window_activity_flag}'` produced
      `%subscription-changed actwatch $0 @1 1 - : 1` the moment the background
      window gained activity. One subscription per connection replaces the
      accidental coupling. The same mechanism would watch `window_zoomed_flag`
      for 4b.1.

### 4b.6 The first paint can print the same output twice

- [ ] **`TmuxOutputRouter.register` returns whether it replayed backlog and the
      only caller drops the value.** Its own doc says the return exists so "the
      caller can decide whether the pane also needs a capture-pane snapshot";
      `SessionViewController.makeSurface` ignores it, so the prime always runs
      and `capture-pane -S -N` re-delivers everything the backlog just did.

      Visible on the app's headline case: show a session whose pane streamed
      between attach and first display — an agent mid-run — and its recent
      output appears twice in scrollback. Reasoning only, not observed.

### 4b.7 Bracketed paste is decided by a reconstructed state

- [ ] ⌘V reaches libghostty's paste, which brackets the text only if *it*
      believes bracketed paste is on — and after any replay it believes nothing
      is on. A multi-line paste into vim after a repaint staircases the
      indentation. tmux has no format variable for the mode, but it tracks it:
      `paste-buffer -p` brackets "if the application has requested bracketed
      paste mode". Going through `load-buffer` + `paste-buffer -p -t %id` makes
      tmux the authority. Reasoning only.

### 4b.8 ⌘1-9 counts slots while the rail shows tmux indices

- [ ] `SessionViewController.selectWindow(atVisibleSlot:)` takes a positional
      index into the hidden-filtered list, while `SidebarRows` draws
      `window.index`. With tmux's default `base-index 0` the row labelled **0**
      is ⌘1 and the row labelled **3** is ⌘4; hide a window and every shortcut
      below it shifts. `TitleBandView`'s comment even claims the rail is what
      ⌘1-9 counts against. Either show slot numbers or select by index —
      `#{base-index}` is queryable.

### Checked and found fine

`%client-session-changed` ignored on purpose and documented. The repaint timing
constants — each stands in for a signal tmux genuinely does not send, and each
is bounded with the honest failure direction. `freeIndexAtEnd`'s margin, the
placeholder cell size, the metrics window, `scrollbackPrimeLines` as a ceiling
tmux clamps. `capture-pane` on an alternate-screen pane returns primary history
plus the alternate screen as text, so the prime's *content* is complete — only
the modes in 4b.3 are missing.

      It predates the first-show fix below; that fix only made it certain to run
      in the case it addresses, and Codex found it while reviewing that fix.
      Fixing it means the model carrying tmux's active pane, and the single
      `list-windows` round trip cannot supply it: `#{window_active_pane}` does
      not exist in tmux 3.6a — verified, it expands to empty. One extra query
      per refresh does, for the whole session at once:
      `list-panes -s -t $id -F '#{window_id} #{pane_id} #{pane_active}'`.
      `%window-pane-changed` is already handled and already triggers a refresh,
      so the notification side needs nothing new.

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
