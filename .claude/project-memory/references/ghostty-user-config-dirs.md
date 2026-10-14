---
name: "libghostty reads the user's Ghostty config"
description: "Embedded libghostty loads the XDG config and Ghostty.app's own com.mitchellh.ghostty config, whatever Casper's bundle id"
type: reference
---

# libghostty reads the user's Ghostty config

`ghostty_config_load_default_files` (called in `GhosttyRuntime`'s config build)
loads, in order:

1. `~/.config/ghostty/config`, then `~/.config/ghostty/config.ghostty` (XDG);
2. `~/Library/Application Support/com.mitchellh.ghostty/config`, then
   `…/config.ghostty`.

The Application Support directory is **`com.mitchellh.ghostty`, the identifier
compiled into libghostty**, not the host app's bundle id: `Casper-dev.app`
(`com.github.alexandreroman.casper.dev`) reads Ghostty.app's own config. The
upstream doc comment on `loadDefaultFiles` says `$CFBundleIdentifier`; the
running binary does not behave that way. Every setting a Ghostty.app user has —
fonts, explicit colours, and the theme picker's
`config-file = ?auto/theme.ghostty` include, resolved by
`ghostty_config_load_recursive_files` — therefore reaches Casper's terminals.

Consequences Casper is built around:

- Casper's built-in defaults (`GhosttyDefaultConfig`) load **first**, so any
  user setting wins over them.
- A Ghostty.app theme is usually a **named** theme (`theme = Arthur`). Casper
  ships no Ghostty resources dir, so a name only resolves from
  `~/.config/ghostty/themes/`; otherwise `GhosttyConfigBuilder` falls back to
  Casper's built-in light/dark themes (see [[ghostty-conditional-themes]]).
- Upstream source (`Config.zig`, `loadDefaultFiles`) writes a commented
  template `config.ghostty` into that Application Support directory when
  neither the XDG nor the Application Support config exists.

**Why:** the directory decides whether Casper inherits a user's whole Ghostty
setup; assuming the opposite hides real interactions such as a user theme
replacing Casper's.

**How to access:** libghostty logs each file it reads — `/usr/bin/log show
--predicate 'process == "casper" AND subsystem == "com.mitchellh.ghostty"'
--last 5m --info` shows `reading configuration file path=…` lines. Related:
[[ghosttykit-pin]], [[ghostty-conditional-themes]].
