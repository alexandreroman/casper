---
name: "titleCapsule() hit area on plain buttons"
description: "Apply .titleCapsule() inside a Button's label, not after .buttonStyle(.plain), or only the glyph is clickable"
type: reference
---

# titleCapsule() hit area on plain buttons

For title-bar capsule chips that are `Button`s with
`.buttonStyle(.plain)`, `.titleCapsule()` MUST be applied **inside** the
`label:` closure (attached to the label content), not chained after
`.buttonStyle(.plain)` on the `Button` itself.

The shared `titleCapsule()` helper (a private `View` extension in
`Sources/CasperUI/WorkspaceDetailView.swift`) adds padding, a background,
and a `.contentShape(Capsule())`. A plain button's hit area is defined by
its **label's** shape. If `titleCapsule()` is applied outside the button,
the capsule is mere decoration over the button and the interactive region
stays limited to the raw label (e.g. just the `Image` glyph) — clicking the
capsule padding/background does nothing.

**Why:** this is exactly how the inspector toggle broke (only the
`sidebar.right` glyph was clickable, not the capsule). The `diffBadge`
button in the same file had it right — `.titleCapsule()` inside the label —
and was the reference for the fix.

**How to access:** the pattern lives in
`Sources/CasperUI/WorkspaceDetailView.swift`; see `inspectorToggle` and
`diffBadge`. Related: [[swiftui-inspector-width]].
