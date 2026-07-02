---
name: "e2e surface creation flakiness"
description: "ghostty_surface_new can return null in some automation sessions, blocking casper debug e2e checks, even with unchanged code"
type: reference
---

# e2e surface creation flakiness

In some Claude Code sessions, launching the debug binary (`.build/debug/casper
&`, per the `debug-casper` skill) never produces a working terminal surface:
`casper debug dump-state` reports `"surfaces": []` forever, and
`/usr/bin/log stream --predicate 'subsystem ==
"com.github.alexandreroman.casper"'` shows
`[ghostty] surface creation failed: GhosttyError(reason: "ghostty_surface_new
returned null")` on every launch. `NSApplication` still starts (LaunchServices
registers it, `ApplicationType` transitions `BackgroundOnly` → `Foreground` as
expected), and `GhosttyRuntime()`/`ghostty_app_new` succeeds — only the
per-surface `ghostty_surface_new` call fails, so the app process stays alive
with a `casper` window that never gets a `contentView` surface.

**This is not necessarily a code regression.** Before concluding a change
broke surface creation, `git stash` back to the last known-good commit,
rebuild, and relaunch — if the failure reproduces identically on unmodified
code, it is environmental, not a regression. (Confirmed this way during the
kbd-task-2 session: identical failure on `main` at `a2f8c98`, before any
edits.)

Things checked that did **not** explain it in that session: display was not
asleep (`system_profiler SPDisplaysDataType` showed no `Display Asleep`
after `caffeinate -u -t 1`), the GUI login session was active
(`launchctl print gui/$(id -u)` showed `type = login`, active), no stray
`casper` process held the socket or a stale lock, waiting longer between
retries did not help, and there was no `~/.config/ghostty/config` to cause a
bad user-config load. Root cause was not found; `kbd-task-1`'s report shows
the exact same launch recipe working normally in an earlier session, so this
looks like a transient/session-specific GPU-or-WindowServer-connection issue
in the automation environment rather than a structural block.

**Confirmed mitigation (kbd-task-3 controller session).** The failure is
tied to the display being asleep / the WindowServer connection being idle in
a long unattended run. A single `caffeinate -u -t 1` is often too short. What
reliably works:

1. `caffeinate -u -t 4 &` right before launch to assert user activity and
   wake the display, then wait ~0.5s.
2. Launch on a dedicated socket, then **poll** `casper debug dump-state`
   until the JSON contains a real surface (`"id"`), up to ~10s — the surface
   often appears within one poll once the display is awake. Do not test
   before it appears.
3. For a long multi-step run, hold the display awake for the duration with a
   background `caffeinate -d -i -t <seconds> &` (killed at the end).

With this recipe, `ghostty_surface_new` succeeded in the same session where a
bare background launch had returned null. So prefer the wake+poll recipe over
declaring the environment blocked; only fall back to build-only verification
if the surface still never appears after ~12s.

**When this happens and the recipe still fails:** treat the e2e step as
blocked by environment, not as a failed check — verify via build success +
source-level reasoning (matching call signatures, diffing against the brief)
instead, and say so explicitly in the task report rather than silently
skipping or inventing an observation.
