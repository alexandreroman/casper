---
name: "e2e surface creation flakiness"
description: "ghostty_surface_new returns null with every display asleep, blocking casper debug e2e checks on unchanged code; wake the display and poll"
type: reference
---

# e2e surface creation flakiness

In some automation sessions, launching the dev app under its own session (the
`Casper-dev.app … --session` launch in the `debug-casper` skill) never produces
a working terminal surface: `casper debug dump-state` reports `"surfaces": []`
forever, and the log shows
`[ghostty] surface creation failed: GhosttyError(reason: "ghostty_surface_new
returned null")` on every attempt. `NSApplication` still starts and
`GhosttyRuntime()`/`ghostty_app_new` succeeds — only the per-surface
`ghostty_surface_new` call fails. `GhosttySurfaceView` retries it up to 3
times, 0.25 s apart, then shows a "Terminal failed to start. Close and reopen
this pane to retry." overlay in the pane; re-entering a window restores the
retry budget. The in-process test harness bounds its surface poll by that same
budget ([[ghostty-real-surface-e2e-harness]]).

**This is environmental, not necessarily a code regression.** The confirmed
mechanism is **no active display**: with every display asleep,
`CGGetActiveDisplayList` reports zero displays, and libghostty's renderer init
(window-vsync on) fails to create its `CVDisplayLink`. The unified log then
shows `CVDisplayLinkCreateWithCGDisplays error -6661 due to invalid display
count (0)` followed by `embedded_window: error initializing surface
err=error.OutOfMemory` (libghostty maps every CVReturn failure to OutOfMemory).
Check for those two lines first; a failure without them has another cause.
`GhosttySurfaceView` restarts a bounded creation cycle on
`NSWorkspace.screensDidWakeNotification` and
`NSApplication.didChangeScreenParametersNotification`, so a view that failed
while the displays slept recovers once they wake — see
[[display-sleep-surface-creation]].
Before concluding a change broke surface creation, build the last known-good
commit in a separate `git worktree add <dir> <commit>` and relaunch it — an
identical failure on unmodified code confirms it is environmental.

**Mitigation recipe (reliable):**

1. `caffeinate -u -t 4 &` right before launch to assert user activity and wake
   the display, then wait ~0.5 s. (A single `caffeinate -u -t 1` is often too
   short.)
2. Launch under a dedicated `--session`, then **poll** `casper debug dump-state`
   until the JSON contains a real surface (`"id"`), up to ~10 s — the surface
   usually appears within one poll once the display is awake. Do not test
   before it appears.
3. For a long multi-step run, hold the display awake with a background
   `caffeinate -d -i -t <seconds> &`, killed at the end.

Prefer this wake+poll recipe over declaring the environment blocked. **If the
surface still never appears after ~12 s**, treat the e2e step as
environment-blocked (not a failed check): verify via build success +
source-level reasoning (matching call signatures, diffing against the brief) and
say so explicitly in the report, rather than silently skipping or inventing an
observation.
