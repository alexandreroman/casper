---
name: "glassEffect renders invisible with a nested Menu"
description: "SwiftUI .glassEffect(in:) on macOS 26 composites as nearly invisible when the wrapped view contains a native Menu styled .menuStyle(.borderlessButton); use an explicit Color background + strokeBorder overlay instead"
type: feedback
---

# glassEffect renders invisible with a nested Menu

When building a custom capsule/pill background around a view hierarchy that
contains a native `Menu` (e.g. `.menuStyle(.borderlessButton)` used for a
toolbar split-button's chevron), `.glassEffect(in: .capsule)` renders the
capsule as nearly invisible — no visible fill contrast — even though the same
modifier renders a clearly visible pill when applied to a plain view (e.g. an
`HStack` of `Text` views, as `WorkspaceDetailView.diffBadge` does).

**Why:** a native menu control mid-hierarchy appears to interfere with how
`.glassEffect` composites/renders its material around it, likely because the
glass effect assumes a single flattened SwiftUI rendering pass and the native
AppKit-bridged `Menu` breaks that assumption. The same construction that renders
a solid, visible pill for `WorkspaceDetailView.diffBadge` renders invisible once
a `Menu` is added inside the same `HStack` (as in `editorButton`).

**How to apply:** for any custom SwiftUI toolbar control whose view hierarchy
contains a native `Menu`/`Picker`/other AppKit-bridged control, skip
`.glassEffect(in:)` for the background and use an explicit, unconditional
`.background(Color.secondary.opacity(0.15), in: Capsule())` plus
`.overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))` to
approximate the native Liquid Glass pill's fill + edge highlight. This is an
approximation, not a pixel-perfect match to the system's automatic toolbar
background (used by plain, unflattened `ToolbarItem`s like the branch-title
capsule) — expect one extra round of human-eyeballed opacity/width tuning.
