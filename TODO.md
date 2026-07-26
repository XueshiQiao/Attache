# TODO

Ordered roughly by what unblocks the most. Read [CLAUDE.md](CLAUDE.md) before
starting — several of these touch code with non-obvious constraints.

---

## 1 · Settings — done

`TmuxGUI/Settings/` holds the store, the chrome theme, and the window.

Deliberately not done, and still worth doing:

- [ ] Ligature and fallback-font settings. Named as a follow-up from the
      start and nothing since has changed that.
- [ ] The multi-pane case of the font change is unverified. The column-count
      check was run against a one-pane window across three font sizes, a
      window resize and a stability poll, all agreeing with `list-panes`;
      switching the shown session needs ⌃⌘n, and driving the keyboard was off
      limits while the machine's owner was using it. Splitter placement is
      arithmetic on the same `cellSize` every checked number came from, so it
      should follow — but "should" is not "was measured".

---

## 2 · Generate the Xcode project from `project.yml`

`TmuxGUI.xcodeproj` is currently hand-maintained — it was copied from
libghostty-spm's sample app and edited with `sed`. That is workable for one
person for a week and bad for everything after: the pbxproj is unreviewable in
a diff, merge conflicts in it are unresolvable by hand, and the settings that
actually matter are buried among a few hundred lines of generated noise.

Move to [XcodeGen](https://github.com/yonaskolb/XcodeGen), the way `AnyDrag`
next door does it: `project.yml` is the single source of truth, `.xcodeproj` is
gitignored and never committed, and `xcodegen generate` rebuilds it.
`brew install xcodegen`; see `~/Code/AnyDrag/project.yml` for the house style.

Things that must survive the migration — each one breaks the app if dropped:

- [ ] **The "Normalize libghostty Framework" run script.** In Debug it moves the
      XCFramework's flat layout into the `Versions/A` shape macOS requires and
      re-signs it. Without it the app does not launch. It is a
      `PBXShellScriptBuildPhase` today; in XcodeGen it becomes a
      `postCompileScripts` or `postBuildScripts` entry on the target. Copy the
      script body verbatim out of the current pbxproj before deleting it.
- [ ] **`ENABLE_APP_SANDBOX = NO`.** A sandboxed process can neither spawn tmux
      nor reach its socket. This is the setting most likely to be silently
      reset to the template default.
- [ ] **The local package reference** to `Vendor/libghostty-spm`. XcodeGen takes
      it as `packages: <name>: {path: Vendor/libghostty-spm}`.
- [ ] `CODE_SIGN_ENTITLEMENTS`, `PRODUCT_BUNDLE_IDENTIFIER` (`dev.xueshi.TmuxGUI`),
      `MACOSX_DEPLOYMENT_TARGET 13.0`, `ENABLE_HARDENED_RUNTIME`.
- [ ] The `TmuxGUI/` folder is a `PBXFileSystemSynchronizedRootGroup` — files are
      picked up automatically without touching the project. XcodeGen's `sources`
      behaves the same way, so keep it that way; do not go back to listing files.

Worth dropping rather than migrating:

- [ ] The `TmuxGUIUITests` target contains nothing but the sample's placeholder.
      Either write a real test or leave the target out.

(`LookInsideServer` was already removed — see section 3.)

Afterwards:

- [ ] Add `*.xcodeproj` to `.gitignore` and `git rm -r --cached` the existing one.
- [ ] Update the build instructions in `README.md` and `CLAUDE.md` to run
      `xcodegen generate` first.
- [ ] Verify by generating from scratch in a clean clone, building, launching,
      and confirming the app attaches to tmux — the framework normalisation
      failure mode is a launch crash, not a build error, so a green build proves
      nothing on its own.

---

## 3 · Make the UI inspectable by an agent

The project used to link `LookInsideServer`, inherited from the libghostty
sample. It is a UI inspector in the [Lookin](https://lookin.work)/Reveal family:
the app embeds a server, a companion Mac app connects, and you get the live view
hierarchy with frames, layers and properties. Exactly the tool that finds
"correct frame, not hidden, alpha 1, `draw(_:)` runs, renders nothing" in
seconds rather than an hour.

It has been removed, because an agent cannot drive it. The server is a closed
binary XCFramework from a private source repo, the port speaks a custom protocol
— probed with a plain HTTP request it returns nothing at all — and only the
companion GUI understands it. That made it pure cost here: a listening socket on
`127.0.0.1` at every launch, and no way for the thing that actually does the
debugging in this project to ask it anything.

The need behind it is real, so build the small version instead:

- [ ] A debug-only view-hierarchy dump: for every view, its class, frame in
      window coordinates, `isHidden`, `alphaValue`, and the layer's frame and
      `masksToBounds`. The layer frame is the field that matters — a backing
      layer larger than its view is what made the tab strip invisible, and no
      amount of screenshotting reveals it.
- [ ] Reachable without a GUI. A menu item that writes JSON to a known path is
      enough and is two dozen lines; a small local HTTP endpoint behind a debug
      flag is nicer and lets an agent poll while driving the app with
      `cliclick`. Do not ship either in Release.
- [ ] Same treatment for tmux state: dump what the app believes about sessions,
      windows, layouts and pane ids, so it can be diffed against `list-windows`
      directly. Two bugs so far — the window counts and the crossed session
      targets — were found by hand-comparing exactly those two things.

This is worth doing before the settings work rather than after. Settings change
fonts, fonts change cell sizes, cell sizes change the grid, and the grid is the
thing whose failures are invisible until a TUI redraws.

---

## 4 · Known defects

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
