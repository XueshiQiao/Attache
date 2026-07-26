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
(`/tmux`, shaped to diff against `list-windows`). The settings work added
write routes so a font change can be driven without a pointer.

The closed-source inspector this replaces is gone for good: an agent could
not read it, which made it pure cost here.

---

## 4 · Known defects

- [ ] **A session shown for the first time can stay blank.**
      `MainViewController.show(sessionNamed:)` never syncs the model itself; it
      waits for tmux to send a notification. Normally masked, because the
      `refresh-client -C` that follows triggers a reflow and the reflow
      notifies. With a window whose size already matches, tmux sends nothing
      and the pane grid stays empty until something else happens to change.
      Found while fixing the font relayout, pre-existing and unrelated to it.
- [ ] **A vanished session leaves its controller behind.**
      `TmuxServer.refreshSessions()` stops the connection of a session that is
      gone, but `MainViewController.controllers[name]` keeps the controller and
      its surfaces, still registered to a router nobody feeds.
- [ ] **A superseded repaint batch is never repainted.** `scheduleRepaint`
      cancels one shared work item, so panes from the cancelled batch are
      skipped entirely — and their `paintedFrames` were already updated, so
      nothing comes back to them. The per-pane retry added for busy panes does
      not cover this.
- [ ] **`TmuxMetrics.Snapshot.report` is dead code** that still prints the gap
      statistics as though they were a general-purpose readout. They mean
      something only inside the A/B probe.

The probe's modal is gone too — it was fixed by the settings work rather than
here, and the bullet outlived it. The report renders inline on the About page;
the only `runModal` calls left are the fatal "no tmux" startup alert and the
confirmation before killing a window, and both should stay.

Five others are fixed. None of them was quite what its bullet said, so what
each turned out to be:

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
