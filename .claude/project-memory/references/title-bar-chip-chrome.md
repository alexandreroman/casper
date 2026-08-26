---
name: "Title-bar chips carry no accent colour"
description: "Title-bar chrome uses one neutral palette; selection is a controlColor indicator, never an accent tint"
type: feedback
---

# Title-bar chips carry no accent colour

`Color.accentColor` has no place in the title-bar chrome: neither a fill nor a
glyph is tinted for state. The capsule chips (`titleCapsule` /
`titleCapsuleShell` in `Sources/CasperUI/WorkspaceDetailView.swift`) use one
neutral palette only: `Color.secondary.opacity(0.15)` at rest and `0.28` under
the pointer. `TitleCapsuleChrome` never touches the label's foreground style, so
every chip keeps the tint it sets for itself (the diff badge's green/red
counters, the title chip's secondary glyph).

## The inspector tabs are one segmented control

Diff and Browser are mutually exclusive, so they share a single
`titleCapsuleShell` enclosing two glyph-only `Button`s (`InspectorTabSelector`).
Selection reads from a single indicator — a `Capsule` filled with
`Color(nsColor: .controlColor)` plus a 0.12-alpha shadow — drawn in the
`.background` of the selected segment only and carried across the two by
`matchedGeometryEffect`, so it slides horizontally rather than cross-fading. The
selected glyph is `Color.primary`, the other `Color.secondary`.

Three states are visible, and the third is what makes the exclusivity legible:
the panel open on Diff, open on Browser, or collapsed — collapsed draws no
indicator at all, leaving a plain neutral capsule.

Hover belongs to the shell as a whole (`titleCapsuleShell(interactive: true)`,
matching the Run / Editor pills); a per-segment hover fill would fight the
sliding indicator.

The segments are glyph-only (`Image(systemName:)`, no visible text); their one
`help` string serves as both the tooltip and the `.accessibilityLabel`.

Each segment reserves a fixed glyph slot (`TitleCapsuleMetrics.glyphSlotWidth`)
inside its 10pt horizontal insets, so both halves are the same width by
construction. SF Symbols carry different intrinsic widths (`plusminus` measures
12pt against `globe`'s 15pt), and content-sized segments therefore come out
lopsided and resize the sliding indicator as it moves. The slot goes *inside*
the padding — see [[fixed-frame-swallows-inner-padding]] — so the insets still
widen the segment and the whole half stays clickable. The resulting geometry is
pinned by `InspectorTabSelectorTests`.
