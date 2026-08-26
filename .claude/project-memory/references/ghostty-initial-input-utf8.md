---
name: "libghostty initial_input mojibakes non-ASCII"
description: "Don't use libghostty's initial_input config field; inject via ghostty_surface_text (UTF-8-safe) post-spawn"
type: reference
---

# libghostty initial_input mojibakes non-ASCII

The pinned libghostty's `ghostty_surface_config_s.initial_input` field expands
EACH BYTE of the queued text as a Latin-1 scalar re-encoded to UTF-8, so any
non-ASCII input is garbled (`…` U+2026 = UTF-8 `E2 80 A6` → `â` + C1-control +
`¦`; `café`, emoji, accented paths all corrupt). It faithfully carries ASCII
only, and no pre-encoding can round-trip through it (it can never emit a raw
high byte).

Casper therefore does NOT set `c.initial_input`. A surface's queued initial
command (`GhosttySurfaceConfiguration.initialInput` — a `.casper.json` script,
`casper run`, `terminal new --command`, `workspace new --command`) is injected
in `GhosttySurface.init`, immediately after `ghostty_surface_new`, via
`sendText` → `ghostty_surface_text` (the same UTF-8-correct path normal typing
uses). Verified live: the command still runs (no lost input from the post-spawn
timing) and `… café 🚀` render correctly.

`c.initial_input` is off limits. Casper likewise avoids libghostty's
`ghostty_surface_config_s.command` field: the pinned fork execs it as
`bash -l -c "exec <command>"` regardless of `$SHELL`, so a command depending on
zsh-only PATH entries (Homebrew, mise, added by `~/.zprofile`/`~/.zshrc`) fails
with `not found`, and `exec` replaces the shell so a compound `a ; b` runs only
`a`. A queued command is instead typed into the real login shell via the
`ghostty_surface_text` path above, which rebuilds PATH from the user's own
profile.
