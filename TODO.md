# TODO

Ordered roughly by what unblocks the most. Read [CLAUDE.md](CLAUDE.md) before
starting — several of these touch code with non-obvious constraints.

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

One open, and it is the invariant this project cares most about:

- [ ] **The app decides which pane is focused instead of reading it from tmux.**
      `SessionViewController.syncWithModel` picks `layout.panes.first` whenever
      it has no focused pane of its own and sends `select-pane`, so showing a
      session for the first time can *move* tmux's active pane — for every
      client attached to that session, not just this app. Demonstrated with
      tmux alone: split a window, make the right pane active, and
      `list-panes -s` reports `@0 %1 active=1` while `%0` is the layout's first
      pane, which is the one the app would select. The mirror case is equally
      wrong — a pane made active from another terminal is ignored for as long as
      the app's own choice is still in the layout, and `send-keys` keeps
      targeting the app's pane. This is the one place the app authors state tmux
      owns.

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

- [ ] **Search** within a pane's scrollback. libghostty has
      `TerminalSurfaceSearchDelegate`; the buffer is already populated.
- [ ] **Copy mode.** tmux has its own; decide whether to drive `copy-mode` or
      use libghostty's selection. Driving tmux keeps the two views consistent.
- [ ] **Multiple app windows.** `MainViewController` assumes one. `TmuxServer`
      would need to be shared rather than owned.
- [ ] **Pane splitting from the GUI.** `split-window` is trivial to send; the
      question is where the affordance lives.
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
