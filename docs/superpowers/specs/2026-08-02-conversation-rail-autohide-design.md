# Conversation rail: corner toggle + auto-hide without an agent

2026-08-02. Approved in conversation; the granularity fork (per window vs per
session) was answered **per window**. Revised the same evening after the first
build shipped a dead end: the owner hid the rail while a no-agent window was on
screen and no number of ⌘\ presses brought it back, because the auto-hide rule
outranked every manual action. The owner supplied Xcode's inspector toggle as
the model to follow.

## What is being built

1. **One button cluster in the title band, top-right of the window** —
   layout "B" from a second HTML mock-up round (2026-08-02, chosen over
   fold-buttons-in-the-title-row and a split-by-purpose layout): collapse
   every turn, expand every turn, a hairline, then the rail toggle, 12pt off
   the window edge so nothing sits inside the rounded corner. The fold pair
   acts on the rail's content, so it vanishes with the rail (and when the
   rail shows only a placeholder); the toggle is the way back and never
   moves — Xcode's inspector interaction. All four views are hosted by
   `MainViewController` as one floating stack over the split view (safe
   because `NSSplitViewController` runs its split view with
   `arrangesAllSubviews` off; asserted at install), synced to the split
   item's *actual* collapsed state via KVO so a divider drag cannot leave
   fold buttons floating over the terminal. The rail itself contains no
   buttons.

2. Auto-hide when the window on screen has no agent. Setting
   `hides_conversation_without_agent` (bool, default **true**) in
   `attache.toml`, surfaced as a toggle on the Behaviour page.

## The visibility rule

```
visible = manualShow || (shows_conversation && (agent detected || !hides_conversation_without_agent))
```

- `manualShow` is the fix for the dead end: **manual beats automatic.**
  Toggling the rail on raises it, so the rail opens even on a no-agent window
  (onto the placeholder). It is scoped to the window being looked at —
  switching windows clears it and the standing rule resumes. Toggling the
  rail off clears it and writes `shows_conversation = false`, so hiding is a
  standing choice while "show me anyway" is a per-window one.
- "Agent detected" is `conversationEvidence(forWindow:) != nil` for the
  active window — the same signal the rail's content follows.
- `shows_conversation` default flipped from `false` to `true`: the old
  default protected people who never run agents from paying ~55 columns for
  an empty panel, and auto-hide removes exactly that cost.

## Mechanics

- `MainViewController.toggleConversationRail()` is the single entry; the
  corner button, ⌘\ and the View menu item all call it.
- The View menu checkmark reflects `isConversationRailVisible` via
  `validateMenuItem`, and the `NSMenuItemValidation` conformance on
  `AppDelegate` is load-bearing: without it Swift never exposes the method to
  Objective-C and AppKit silently never calls it (first build's mistake,
  caught by Codex review).
- A divider drag survives auto-hide cycles: the rail's actual width is
  captured at the moment of collapse and restored on expand
  (`preservedConversationWidth`). A change to the `conversation_width`
  setting outranks the preserved value (Codex review's second finding).
- While the rail is not visible, `ConversationController.follow(nil)` stops
  the transcript file watcher.

## Not in scope

No animation change. No persistence for `manualShow` — it is a fact about
looking, like `expandedSessions`, not a preference.
