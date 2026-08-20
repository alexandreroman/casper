---
name: "libghostty `ghostty_surface_set_occlusion` parameter is `visible`, not `occluded`"
description: "the bool passed to ghostty_surface_set_occlusion means visible (true = on-screen, render); false pauses the render thread — inverting it silently freezes visible surfaces"
type: reference
---

# libghostty `ghostty_surface_set_occlusion` parameter is `visible`, not `occluded`

`void ghostty_surface_set_occlusion(ghostty_surface_t, bool)` takes a **`visible`**
flag: `true` = the surface is on screen → keep rendering; `false` = occluded →
libghostty pauses the surface's render thread. The vendored header carries no doc
comment, so the polarity is only discoverable from the source. Authoritative
definition, Ghostty v1.3.1 `src/apprt/embedded.zig`:
`export fn ghostty_surface_set_occlusion(surface, visible: bool) { surface.occlusionCallback(visible); }`.
`ghostty_surface_set_focus` and `ghostty_app_set_focus` follow the same
convention (`true` = active/focused).

**Why:** passing the inverse (an "occluded" bool, i.e. `!visible`) silently freezes
rendering on every *visible* surface — the terminal grid still updates from the PTY
(so `casper debug read-text` looks correct) but no frames are drawn, so typed
characters never appear and a new split shows a blank pane. It escapes the unit
tests (they can only assert the app's own bookkeeping bool, not libghostty's real
rendering) and `read-text`; only a screenshot or a human eye catches it — which is
why the render-level behaviour needs manual/on-device verification, not just green
tests.

**How to access:** the pinned reference lives at
`https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/src/apprt/embedded.zig`
— grep the `ghostty_surface_*` / `ghostty_app_*` C exports for the real parameter
names before assuming a bool's polarity. When embedding, compute surface visibility
as `window != nil && window.occlusionState.contains(.visible)` and pass THAT as the
bool. In Casper the single wrapper is `GhosttySurface.setOcclusion` (it negates
because its own `occluded` argument is the inverse). See [[ghostty-is-the-reference]],
[[ghosttykit-pin]].
