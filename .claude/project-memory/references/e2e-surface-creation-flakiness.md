---
name: "e2e surface creation flakiness"
description: "ghostty_surface_new can return null in some automation sessions, blocking casper debug e2e checks even on unchanged code; wake the display and poll before declaring it blocked"
type: reference
---

# e2e surface creation flakiness

In some automation sessions, launching the debug binary
(`.build/debug/casper &`, per the `debug-casper` skill) never produces a working
terminal surface: `casper debug dump-state` reports `"surfaces": []` forever,
and the log shows
`[ghostty] surface creation failed: GhosttyError(reason: "ghostty_surface_new
returned null")` on every launch. `NSApplication` still starts and
`GhosttyRuntime()`/`ghostty_app_new` succeeds — only the per-surface
`ghostty_surface_new` call fails, so the process stays alive with a window that
never gets a `contentView` surface.

**This is environmental, not necessarily a code regression.** The failure tracks
the display being asleep / the WindowServer connection being idle in a long
unattended run; it is not explained by display sleep state alone, an active
login session, a stray process holding the socket, or a bad user Ghostty config.
Before concluding a change broke surface creation, `git stash` to the last
known-good commit, rebuild, and relaunch — an identical failure on unmodified
code confirms it is environmental.

**Mitigation recipe (reliable):**

1. `caffeinate -u -t 4 &` right before launch to assert user activity and wake
   the display, then wait ~0.5 s. (A single `caffeinate -u -t 1` is often too
   short.)
2. Launch on a dedicated socket, then **poll** `casper debug dump-state` until
   the JSON contains a real surface (`"id"`), up to ~10 s — the surface usually
   appears within one poll once the display is awake. Do not test before it
   appears.
3. For a long multi-step run, hold the display awake with a background
   `caffeinate -d -i -t <seconds> &`, killed at the end.

Prefer this wake+poll recipe over declaring the environment blocked. **If the
surface still never appears after ~12 s**, treat the e2e step as
environment-blocked (not a failed check): verify via build success +
source-level reasoning (matching call signatures, diffing against the brief) and
say so explicitly in the report, rather than silently skipping or inventing an
observation.
