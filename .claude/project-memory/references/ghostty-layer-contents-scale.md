---
name: "Ghostty Metal layer contentsScale"
description: "Embedding gotcha: sync the libghostty CAMetalLayer contentsScale to the window backingScaleFactor, or the render is upscaled ×2"
type: reference
---

# Ghostty Metal layer contentsScale

When embedding libghostty in an AppKit `NSView`, the host **must** set the
view's `layer.contentsScale` to `window.backingScaleFactor` (and re-set it on
every backing/screen change). libghostty attaches its own `CAMetalLayer` to the
view and renders at the native pixel size passed via `ghostty_surface_set_size`
(e.g. 1800×1120 for a 900×560 pt view on a 2× display). But that Metal layer's
`contentsScale` defaults to `1.0`; if the window is at `backingScaleFactor 2.0`,
Core Animation treats the native-resolution contents as 1× and **upscales them
×2 during compositing**. Symptom: every glyph/cell renders at double size and
the terminal grid overflows the window — text truncated at the right edge — even
though `ghostty_surface_size` reports a correct, self-consistent grid (columns ×
cell_width_px ≈ width_px).

`wantsLayer = true` does **not** fix this: AppKit's auto-managed scale applies
to the layer AppKit creates, not to the Metal layer libghostty substitutes.

Fix in `CasperGhostty/GhosttySurfaceView.swift` — mirror Ghostty's reference
`SurfaceView_AppKit.swift` (`viewDidChangeBackingProperties`), wrapping the
change in a `CATransaction` with actions disabled to avoid a scale animation:

```swift
private func syncLayerContentsScale() {
    guard let window else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contentsScale = window.backingScaleFactor
    CATransaction.commit()
}
```

Call it right after the surface is created (`viewDidMoveToWindow`, before
`pushContentScale`/`pushSize`) **and** at the top of
`viewDidChangeBackingProperties` (so moving between displays of different DPI
re-syncs it).

**Why it matters:** the pixel size and `set_content_scale` values fed to
libghostty were already correct here — the bug is purely in Core Animation
compositing, so the ×2 ratio equals `backingScaleFactor` exactly. This is a
compositing concern distinct from the grid geometry.

**How to verify:** `casper debug dump-state` reports `cellWidthPixels`; measure
the rendered cell from a `casper debug screenshot` (pixel width of a
known-length string ÷ its character count) and confirm the ratio is 1.0, not
2.0.

See [[ghosttykit-pin]].
