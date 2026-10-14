---
name: "Terminal surfaces need an active display"
description: "With every display asleep ghostty_surface_new fails; Casper retries on display wake and never creates vsync-less surfaces"
type: project
---

# Terminal surfaces need an active display

libghostty (v1.3.1, window-vsync on) creates a `CVDisplayLink` in renderer init.
With every display asleep there is no active display, that creation fails, and
`ghostty_surface_new` returns null. Any surface first attempted then — notably a
background workspace's terminal hosted in the off-screen nursery by
`casper workspace new --command` — gets no PTY until a display is active.

Casper's answer is to **recover on display wake**: `GhosttySurfaceView` observes
`NSWorkspace.screensDidWakeNotification` and
`NSApplication.didChangeScreenParametersNotification` and restarts a bounded
creation cycle for a hosted, non-invalidated view that has no surface. The
queued command therefore runs when the displays wake, without the user having
to select the workspace.

Casper does **not** create surfaces without vsync while the displays sleep.
libghostty has no per-surface config: a vsync-less surface means swapping the
app config (`ghostty_app_update_config`) around `ghostty_surface_new`, which
pushes a config change to every live surface twice — resetting any font size
Casper applied through the `font_size` surface option (libghostty keeps a size
across reloads only when a font-size binding set it) — and the surface stays
vsync-less for life, since a display link is only ever created at renderer
init.

**Why:** the user weighed both and chose wake recovery alone: the command
starting at wake is enough, and the config swap's side effects on every open
terminal are not worth an immediate start while nobody is looking.

**How to apply:** do not propose a vsync-less creation path or an app-config
swap to start terminals while the displays sleep. Keeping the display awake
(`caffeinate -d -w <casper-pid>`) is the user-side workaround for an immediate
start. See [[background-surface-nursery]],
[[e2e-surface-creation-flakiness]], [[ghosttykit-pin]].
