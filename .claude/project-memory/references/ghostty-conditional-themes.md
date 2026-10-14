---
name: "Ghostty conditional themes"
description: "How libghostty v1.3.1 resolves theme = light:…,dark:…, what the embedder must do on a scheme switch, and its precedence traps"
type: reference
---

# Ghostty conditional themes

Facts about the pinned libghostty v1.3.1 that Casper's light/dark terminal
rests on (`GhosttyDefaultConfig`, `GhosttyThemeFiles`, `GhosttyConfigBuilder`,
`GhosttyRuntime.setColorScheme`). Source of truth: upstream Ghostty at tag
`v1.3.1`, `src/config/Config.zig` (`loadTheme`, `finalize`,
`changeConditionalState`), `src/config/theme.zig`, `src/App.zig`,
`src/Surface.zig`, and the macOS app's `AppDelegate.swift` /
`Ghostty.App.swift`.

- **Precedence.** An explicit colour key (`background`, `palette`, …) beats a
  theme whichever file set it: the theme loads first and every config step is
  replayed over it. Built-in defaults delivered as explicit keys therefore mask
  a user's `theme`. `theme` is a single field: the last value wins outright, and
  a single name sets light = dark (no switching).
- **Theme paths.** An absolute path is opened directly. A bare name resolves
  only from the user themes dirs or Ghostty's resources dir — Casper has no
  resources dir, so a named theme such as `Arthur` does not resolve.
- **Failures are diagnostics, never errors.** A theme that cannot load adds a
  `ghostty_config_get_diagnostic` entry (`theme "<name>" not found, …`,
  `failed to load theme …`, `not reading theme from …`) and loads no colours,
  leaving libghostty's vanilla `#282c34`.
- **Files are re-read on every switch.** `changeConditionalState` replays the
  steps and runs `finalize` again, which re-opens the selected theme file. Theme
  files must stay on disk for the app's lifetime.
- **State defaults to light**, and `finalize` resolves only the active side, so
  a broken dark side of a conditional theme yields no diagnostic at startup.
- **The embedder drives the switch.** `ghostty_app_set_color_scheme` updates
  the app's state (new surfaces inherit it); each existing surface switches only
  through its own `ghostty_surface_set_color_scheme`. Each call raises a soft
  `RELOAD_CONFIG`, delivered synchronously from inside the setter; libghostty
  pushes nothing itself, so the embedder answers with
  `ghostty_app_update_config` / `ghostty_surface_update_config`, passing the
  stored unconditioned config (which `ghostty_app_new` does not own). That
  update then emits `CONFIG_CHANGE`.
- **Observable from a shell.** `CSI ? 996 n` answers `CSI ? 997 ; 1 n` (dark) or
  `; 2 n` (light) from the surface's conditional state; `OSC 11 ; ?` answers the
  live background. Both verify a running terminal without screenshots.

**Why:** these rules are invisible from the C header and each one, missed,
fails silently — a masked user theme, a terminal that never switches, or a
vanilla gray after a theme file disappears.

**How to access:** read the upstream files above at tag `v1.3.1` (the fork's
header is `Vendor/ghostty/ghostty.h`). Related: [[ghosttykit-pin]],
[[ghostty-is-the-reference]].
