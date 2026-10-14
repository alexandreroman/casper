---
name: "Title-bar chips carry no accent colour"
description: "Title-bar chrome uses one neutral palette; selection is a controlColor indicator, never an accent tint"
type: feedback
---

# Title-bar chips carry no accent colour

`Color.accentColor` has no place in the title-bar chrome: neither a fill nor a
glyph is tinted for state. The capsule chips (`titleCapsule` /
`titleCapsuleShell` in `Sources/CasperUI/TitleChipChrome.swift`) use one
neutral palette only: `Color.secondary.opacity(0.15)` at rest, `0.28` under
the pointer and `0.40` while pressed (`TitleChipFeedback` holds the three
steps). `TitleCapsuleChrome` never touches the label's foreground style, so
every chip keeps the tint it sets for itself (the diff badge's green/red
counters, the selector's primary and secondary glyphs).

## The inspector tabs are one segmented control

Diff and Browser share a single `titleCapsuleShell` enclosing two glyph-only
`Button`s (`InspectorTabSelector`, whose doc comment carries the three visible
states and why the control is one capsule). Selection reads from a single
indicator — a `Capsule` filled with `Color(nsColor: .controlColor)` plus a
0.12-alpha shadow — drawn in the `.background` of the selected segment only and
carried across the two by `matchedGeometryEffect`, so it slides horizontally
rather than cross-fading. The selected glyph is `Color.primary`, the other
`Color.secondary`. Hover belongs to the shell as a whole, matching the Run /
Editor pills; a per-segment hover fill would fight the sliding indicator.

Each segment reserves a fixed glyph slot (`TitleCapsuleMetrics.glyphSlotWidth`,
whose doc comment carries the measured symbol widths) inside its 10 pt
horizontal insets, per [[sf-symbol-widths-need-a-slot]]. The slot goes *inside*
the padding — see [[fixed-frame-swallows-inner-padding]] — so the insets still
widen the segment and the whole half stays clickable. The
resulting geometry is pinned by `InspectorTabSelectorTests`.
