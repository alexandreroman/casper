---
name: "Surface identity"
description: "Every Surface has a unique, stable id invariant across kind, state, and UI location; all UI identity anchors on it"
type: feedback
---

# Surface identity

Every surface — terminal, browser, diff — carries a unique, stable
`Surface.id: UUID`, assigned at creation and persisted. This id must never
change — it is invariant across the surface's **kind** (terminal/browser/diff),
its **state** (agent state, todos, focus, activity), and its **location in the
UI** (which split or tab group, before or after any `LayoutTree` restructuring).

**Why:** `Surface.id` is the single identity anchor the whole UI relies on — the
persistent surface-view cache (`AppModel.surfaceViews`, keyed by `Surface.id` so
a terminal's PTY survives splits, collapses, and reorders), SwiftUI
`.id(surface.id)`, focus tracking (`focusedSurfaceID`), and the Ghostty
first-responder focus callback. Any fabricated or derived identity (for example
a node id computed from a child subtree's first surface) breaks this guarantee
and must be avoided.

**How to apply:** never regenerate a surface id when moving it in the tree —
`LayoutTree` operations move `Surface` values verbatim and mint new ids only for
genuinely new surfaces. UI hosting for every surface kind keys off `Surface.id`
through the surface-view cache. Do not attach identity to a surface's kind,
state, or position.
