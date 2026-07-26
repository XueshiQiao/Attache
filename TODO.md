# TODO

Ordered roughly by what unblocks the most. Read [CLAUDE.md](CLAUDE.md) before
starting — several of these touch code with non-obvious constraints.

---

## 1 · Settings

The app has no configuration at all today: font, size and colours are whatever
libghostty defaults to, and every one of them is hard-coded at the
`TerminalController` builder in `SessionViewController`.

### 1.1 A settings store

- [ ] `AppSettings` backed by `UserDefaults`, with typed accessors and a change
      notification so open surfaces can react without a relaunch.
- [ ] Decide the migration story early: a settings file that gains keys must
      keep the ones it does not recognise. Dropping unknown keys on write makes
      downgrades destructive.

### 1.2 Font family and size

- [ ] Font family picker and a size control.
- [ ] Apply through the `TerminalController` builder — libghostty takes
      `font-family` and `font-size` as config keys, the same way
      `window-padding-x` is set today.
- [ ] **Changing the font changes the cell size, which changes the grid.** This
      is the part to be careful with. `PaneGridView` learns the cell size from
      whatever a surface reports (`adoptCellSize`) and re-measures the surface
      overhead (`calibrate`), so in principle it follows automatically — but
      `adoptedCellSize` in `SessionViewController` is a one-shot latch and will
      need to reset on a font change. Verify afterwards that tmux and the app
      still agree on the column count exactly; a one-column drift is the bug
      described in CLAUDE.md and it is not visually obvious until a TUI
      redraws.
- [ ] Ligature and fallback-font settings are a reasonable follow-up, not part
      of the first pass.

### 1.3 Themes

- [ ] Light and dark to start, following the system appearance by default with
      an explicit override.
- [ ] **`GhosttyTheme` already ships 485 terminal colour schemes** (from
      iTerm2-Color-Schemes) and is already a dependency — see
      `Vendor/libghostty-spm/Sources/GhosttyTheme`. Prefer wiring that up over
      inventing a theme format.
- [ ] Design the theme type so a scheme can be added without touching the
      picker: a named list the UI enumerates, not a switch statement.
- [ ] The GUI chrome needs to follow too — the tab strip, session rail and
      splitter colours currently come from system semantic colours, which
      handles light/dark but not a user-chosen scheme. Decide whether chrome
      tracks the terminal theme or stays system-native.
- [ ] `cgColor` snapshots the appearance current at the call site. Anything set
      on a layer must be re-resolved in `viewDidChangeEffectiveAppearance`, as
      `SessionRowView` and `WindowTabItemView` already do.

### 1.4 The settings window itself

- [ ] A plain `NSWindow` with a tabbed layout is enough; there is no settings UI
      of any kind yet, so this is greenfield.
- [ ] Add ⌘, to the app menu.
- [ ] Worth exposing while the window exists: scrollback prime size
      (`SessionViewController.scrollbackPrimeLines`), sidebar width, and whether
      closing a tab hides or kills.

---

## 2 · Known defects

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

## 3 · Features not started

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

## 4 · Not yet reviewed

The whole codebase was written in one pass with verification-by-running but no
independent review. A review pass should look hardest at:

- Threading in `TmuxControlClient` and `TmuxOutputRouter` — the reader queue
  touches state the main thread also reads, guarded by `NSLock`.
- The `%begin`/`%end` reply pairing. It is a FIFO of completions, gated on the
  attach handshake so tmux's own unsolicited block cannot desync it, but it has
  not been tested against a command that errors mid-stream.
- Lifetime of the closures wired between surfaces, connections and views.
