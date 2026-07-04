---
name: "Pending: verify inspector resize after onGeometryChange switch"
description: "Manual GUI check owed for the macOS-15 onGeometryChange simplification of the inspector width"
type: project
---

# Pending: verify inspector resize after onGeometryChange switch

`InspectorPanel.swift` and `SurfaceHostView.swift` were simplified to
`.onGeometryChange` (macOS 15+), replacing the older root-`GeometryReader` +
`.onChange` measurement (see [[swiftui-inspector-width]]). The build passes, but
the interactive resize round-trip was **not** verified: the debug session could
not present a drivable window (`ghostty_surface_new returned null`, 0 windows —
see [[e2e-surface-creation-flakiness]]).

**Manual test owed:** open Casper, expand a workspace's inspector, drag its left
divider to a new width, quit, reopen — the inspector must restore at the width
it was left. If it does, the change is confirmed and this note can be deleted.
