---
name: "titleCapsule() hit area on plain buttons"
description: "Apply .titleCapsule() inside a Button's label, not after .buttonStyle(.plain), or only the glyph is clickable"
type: reference
---

# titleCapsule() hit area on plain buttons

For title-bar capsule chips that are `Button`s with `.buttonStyle(.plain)`,
`.titleCapsule()` MUST be applied **inside** the `label:` closure (attached to
the label content), not chained after `.buttonStyle(.plain)` on the `Button`
itself.

The shared `titleCapsule()` helper (a private `View` extension in
`Sources/CasperUI/WorkspaceDetailView.swift`) adds padding, a background, and a
`.contentShape(Capsule())`. A plain button's hit area is defined by its
**label's** shape. If `titleCapsule()` is applied outside the button, the
capsule is mere decoration over the button and the interactive region stays
limited to the raw label (e.g. just the `Image` glyph) — clicking the capsule
padding/background does nothing.

**Why:** the failure is silent. The capsule renders exactly right and only the
click target is wrong, so it survives visual review — typically as a chip whose
glyph works and whose padding does nothing. `diffBadge`
(`Sources/CasperUI/WorkspaceDetailView.swift:216`) is the reference for the
correct shape: `.titleCapsule()` sits inside the `label:` closure, so the whole
pill is live.

## Split-button chips (Run Script / Editor)

Split buttons (primary `Button` + borderless `Menu` sharing one capsule) CANNOT
put `.titleCapsule()` inside a single label — there are two controls, and
`titleCapsule()` on the enclosing `HStack` puts its `.padding(.horizontal,
10)` and `.frame(height: 36)` OUTSIDE both controls, so only the primary
`Label`'s glyph/text is clickable (the exact "Run Script only clickable on the
icon" bug). No child can reach into the capsule's outer padding.

Fix: split the helper. `titleCapsuleShell(filled:interactive:)` applies
everything except the horizontal padding (`.frame(height: 36)`, background,
border overlay, `.contentShape(Capsule())`); `titleCapsule(filled:interactive:)`
= `.padding(.horizontal, 10)` + `titleCapsuleShell`. (`interactive: true` adds
the hover highlight for chips that are buttons.) Split buttons finish the
`HStack` with `.titleCapsuleShell()` and move the interior geometry INSIDE each
control's label: on the primary button's label add `.padding(.leading, 10)`,
`.padding(.trailing, 4)`, `.frame(maxHeight: .infinity)`,
`.contentShape(Rectangle())` (never `maxWidth: .infinity` — the button must stay
content-sized or it stretches the toolbar); on the `Menu` add
`.padding(.trailing, 10)`. Visible result is pixel-identical, and the full pill
height plus its leading padding all fire the primary action.

**How to access:** the pattern lives in
`Sources/CasperUI/WorkspaceDetailView.swift`; see `diffBadge` (`:216`) for the
single-button form (capsule inside the label) and `TitleSplitButton` (`:363`)
for the split-button form (`titleCapsuleShell` + interior padding), which
`editorButton` and `ScriptToolbarButton` both render.
Related: [[swiftui-inspector-width]].
