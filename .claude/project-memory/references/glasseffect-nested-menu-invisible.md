---
name: "glassEffect renders invisible with a nested Menu"
description: "SwiftUI .glassEffect(in:) on macOS 26 composites as nearly invisible when the wrapped view contains a native Menu styled .menuStyle(.borderlessButton); use an explicit Color background + strokeBorder overlay instead"
type: feedback
---

# glassEffect renders invisible with a nested Menu

This note is why `.glassEffect` appears nowhere in `Sources/`.

When a custom capsule/pill background wraps a view hierarchy containing a
native `Menu` (e.g. `.menuStyle(.borderlessButton)` for a toolbar split
button's chevron), `.glassEffect(in: .capsule)` composites as nearly invisible
— no fill contrast at all — even though the same modifier renders a clearly
visible pill over a plain `HStack` of `Text`.

**Why:** a native menu control mid-hierarchy interferes with how `.glassEffect`
composites its material, most likely because the effect assumes a single
flattened SwiftUI rendering pass and the AppKit-bridged `Menu` breaks that
assumption. Measured on `WorkspaceDetailView`'s split-button chip: the exact
construction that renders a solid pill without a `Menu` renders invisible with
one inside the same `HStack`.

**How to apply:** for any custom SwiftUI toolbar control whose hierarchy
contains a native `Menu`/`Picker`/other AppKit-bridged control, skip
`.glassEffect(in:)` and paint the background explicitly. `TitleCapsuleChrome`
in `Sources/CasperUI/WorkspaceDetailView.swift` — reached through
`.titleCapsule(interactive:)`, which `diffBadge` and every other chip uses — is
the shipped form of that: an unconditional fill plus a `strokeBorder` overlay
approximating the Liquid Glass pill's fill and edge highlight. It is an
approximation, not a pixel match to the system's automatic toolbar background
(used by plain, unflattened `ToolbarItem`s), so a change there costs one round
of human-eyeballed opacity/width tuning.
