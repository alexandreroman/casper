---
name: "inherited_config reports a surface's live font size"
description: "The read-back the font-size persistence rests on, and the update_config alternative that was rejected"
type: reference
---

# inherited_config reports a surface's live font size

`ghostty_surface_inherited_config` reports a surface's **current** font size,
including runtime adjustments made through Cmd+/Cmd-/Cmd0 — not merely the size
the surface was created with. `GhosttySurface.currentFontSize()`
reads it right after each font-size binding action, and the value is what
`Surface.fontSize` persists and replays on restore.

**Why it is worth recording:** the function's documented purpose is building a
config for a *new child* surface, so reading a live value back out of it is a
use the header only implies. The behaviour was confirmed by a deliberate spike
before the feature was built on top of it — change a terminal's font size, call
`currentFontSize()`, check the value moved — precisely because the whole capture
mechanism collapses if it echoes creation-time config instead.
`Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift` is the standing guard: if
it starts failing, this assumption is what broke.

**The rejected alternative,** should that day come: track the size purely in
Swift and push it with `ghostty_surface_update_config`, bypassing libghostty's
own increase/decrease/reset actions. It was turned down because there is no
per-surface `set` API for font size — `update_config` takes a whole
`ghostty_config_t`, a mechanism meant for reloading the entire user config
rather than overriding one field — and because it would duplicate libghostty's
step, minimum and maximum logic in Swift, against the rule that Ghostty is the
reference implementation ([[ghostty-is-the-reference]], [[ghosttykit-pin]]).

`nil` means "not customized": restore leaves libghostty's own default alone
rather than writing a size back.
