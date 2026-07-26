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
- [ ] **Teardown runs twice per shown session.** `MainViewController.stop()`
      stops each `SessionViewController`, then `server.stop()` stops every
      connection again, so a session that was ever displayed gets
      `detach-client` and `SIGTERM` twice. Visible in the log at shutdown. No
      damage observed — but "the close path runs twice" is the shape of a bug
      that only bites at a boundary.
- [ ] **Probe report blocks the run loop.** It appears in
      `NSAlert.runModal()`, and main-queue work queues up behind the modal run
      loop while it is open — the window title stops updating. Use a non-modal
      panel.
- [ ] **The stall figure inflates when a pane is idle.** Gaps between output are
      not stalls if there was nothing to send. Either gate the readout on recent
      activity or drop it from the footer and leave the A/B probe as the number
      that means something.
- [ ] **`capture-pane` replies decode as `String`.** Invalid UTF-8 becomes
      U+FFFD. Only affects snapshots — live `%output` takes the byte path — but
      the reply block should be handled on bytes for the same reason `%output`
      is.
- [ ] **Repaint after resize can overwrite live output.** A busy pane gets a
      snapshot painted over it 150ms after a geometry change. Harmless in
      practice so far, but a pane that is mid-escape-sequence when the snapshot
      lands would garble.

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
