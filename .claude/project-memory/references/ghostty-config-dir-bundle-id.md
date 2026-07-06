---
name: "libghostty macOS config dir is bundle-id scoped"
description: "Embedded libghostty resolves the user config dir from the host app's bundle id; a bundled Casper.app misses the user's Ghostty config, so a default theme is baked in"
type: reference
---

# libghostty macOS config dir is bundle-id scoped

On macOS, `ghostty_config_load_default_files` resolves the user config
directory `~/Library/Application Support/<CFBundleIdentifier>/` from the
**running host app's bundle identifier**, not from a hardcoded
`com.mitchellh.ghostty`.

**Consequence for Casper:**

- **Bundled `Casper.app`** (bundle id `com.alexandreroman.casper`) looks in
  `~/Library/Application Support/com.alexandreroman.casper/` — empty — so it
  gets none of the user's real Ghostty config and falls back to libghostty's
  compiled vanilla default (`background = #282c34`, a gray). Verify the vanilla
  default with `ghostty +show-config --default`.
- **Dev (`swift run casper` / `make dev`)** is a bare binary with no bundle id,
  so libghostty falls back to Ghostty's own `com.mitchellh.ghostty` dir and
  *accidentally* picks up the user's real Ghostty theme (hence dev looked
  darker than the bundle). The XDG `~/.config/ghostty/config` (HOME-based, not
  bundle-scoped) is read by both dev and bundle.

**Why:** this explains why `Sources/CasperGhostty/GhosttyDefaultConfig.swift`
exists — Casper bakes in a self-contained default theme (inline colors, no
`themes/` dir needed) and loads it via `ghostty_config_load_file` **before**
`ghostty_config_load_default_files` in `GhosttyRuntime.init`, so the bundle has
a sane dark default while the user's own config still overrides it (Ghostty
applies files in load order, last wins).

**How to access:** compare `ghostty +show-config` (resolved) vs
`ghostty +show-config --default` (vanilla) to see what a given environment
actually resolves. libghostty exposes no load-from-string API — only
`ghostty_config_load_file` (see `Vendor/ghostty/ghostty.h`) — so an embedded
config must go through a temp file. Related: [[ghosttykit-pin]].
