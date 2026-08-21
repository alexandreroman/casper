---
name: "libghostty scroll mods packed layout"
description: "ghostty_input_scroll_mods_t is an opaque int with a packed-i32 layout; the precision bit is mandatory for trackpad"
type: project
---

# libghostty scroll mods packed layout

`ghostty_input_scroll_mods_t` is declared as an opaque `int` in the vendored
header (`Vendor/ghostty/ghostty.h`), but its real layout is a packed i32: bit 0
= `precision` (deltas are pixels, not lines), bits 1–3 = `momentum` (the
`ghostty_input_mouse_momentum_e` raw value). Remaining bits are padding.

`GhosttySurfaceView.scrollWheel` must set the precision bit for trackpad
(`event.hasPreciseScrollingDeltas`) deltas and encode `event.momentumPhase` into
bits 1–3 (`mods |= Int32(momentum.rawValue) << 1`).

**Why:** without the precision bit, libghostty interprets precise pixel deltas
as line counts, so trackpad scrolling runs far too fast — this was the "terminal
scroll too fast" bug. The header documents none of this layout, so it must be
reconstructed from Ghostty's Swift source (see [[ghostty-is-the-reference]]).

**How to apply:** when touching scroll forwarding, build a `var mods: Int32`, OR
in the precision bit inside the `hasPreciseScrollingDeltas` block, and OR in the
momentum via the static `ghosttyMomentum(for:)` helper. See also
[[ghostty-mouse-parity]].
