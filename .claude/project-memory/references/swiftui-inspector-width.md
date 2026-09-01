---
name: "Custom resizable inspector panel"
description: "Why Casper hand-rolls the inspector panel instead of SwiftUI's native .inspector, and how it resizes"
type: reference
---

# Custom resizable inspector panel

Casper's inspector is a **hand-rolled side panel**, not SwiftUI's native
`.inspector`. `Sources/CasperUI/WorkspaceDetailView.swift` lays it out — a plain
`HStack` of the detail area, a self-drawn draggable divider, and the panel
pinned via `.frame(width:)` — and `Sources/CasperUI/InspectorPanel.swift`
renders the panel's own content.

**Why not the native `.inspector`:** on macOS 26 it **aborts the instant its
divider is dragged**. The AppKit-hosted `SplitViewChildController` reports a
changed hosted-content min/max mid-pass and re-invalidates the window's
constraints, looping until AppKit exceeds its budget (`NSException`: "more
Update Constraints in Window passes than there are views in the window", thrown
from `-[NSSplitView mouseDown:]`). This is a pre-existing framework bug; the
native inspector resize had never been exercised interactively on macOS 26. The
native inspector also never reported the user-resized width back (no `Binding`
overload of `inspectorColumnWidth`; feeding a live-measured width into
`.inspectorColumnWidth(ideal:)` was itself reentrant and fragile). Moving the
inspector out of the `NavigationSplitView`'s `NSSplitView` into a pure SwiftUI
`HStack` removes the `SplitViewChildController` from the path entirely, so the
divider is a normal SwiftUI gesture that cannot trigger the loop.

**Open/close animation — reveal by clip width, do NOT mount/unmount with a
`.move` transition.** The panel is **always mounted**; collapsing animates a
**trailing-pinned clip width** (`0 ↔ divider+panel`, `alignment: .trailing` +
`.clipped()`) so the panel content sits at fixed coordinates and is *revealed*,
not translated. A `.transition(.move(edge: .trailing))` looks right on paper
but breaks any AppKit-hosted view inside the panel: a freshly inserted `NSView`
is laid out straight at its final frame and never follows a SwiftUI
transition's per-frame offset, so it lags the sliding chrome. The rule was paid
for by an `NSSegmentedControl` behind an early segmented-`Picker` tab strip; the
tab strip is hand-rolled SwiftUI (`InspectorTabSelector` in
`WorkspaceDetailView.swift`), and the constraint survives it because the panel
still hosts AppKit content — the terminal's Metal layer and `WKWebView`. This
mirrors `SplitContainerView`, which animates hosted Metal views by frame/offset
on always-mounted views for the same reason. Since
the panel stays mounted while collapsed, `InspectorPanel` **gates its heavy
`content`** (the diff / browser views) on the expanded state, so no diff
computation or `WKWebView` runs while collapsed. Trailing (not leading)
alignment is load-bearing: the detail area is `maxWidth: .infinity`, so the
inspector's *right* edge is fixed and its *left* edge moves — leading alignment
translates the tabs and brings the lag back.

**Divider drag — the shared AppKit `SplitterHandle`** (`SplitContainerView`),
the same grab strip the terminal splits use. It snapshots the boundary at
`mouseDown` and maps absolute window movement onto it, so the inspector's width
is `total - target`. Two of its properties are load-bearing. Tracking the
pointer by **absolute** location, rather than by accumulated translation, is
what keeps the divider locked to it: the divider shifts as the panel resizes, so
a translation-based drag **lags/jitters**. And a concrete `NSView`, rather than
a SwiftUI `.pointerStyle` plus a `DragGesture`, is what wins the resize cursor
over the terminal surface's own `cursorUpdate` — see
[[terminal-overlay-cursor]].

**The grab strip lives OUTSIDE the clipped container.** `.clipped()` clips
hit-testing as well as drawing, so a `SeparatorMetrics.grabWidth` strip mounted
beside the line — inside the clip that reveals the panel — answers only on its
panel-side half, and the half straddling the terminal is dead. The strip is
therefore an overlay on the full-width container, offset to stay centred on the
line for every panel width, while the visible 1 pt hairline stays inside the
clip so it reveals with the panel.

**Why:** every one of these is non-obvious and each was paid for with a live
debug session — the crash is a silent framework limitation, a translation-based
drag looks correct but feels laggy, and a grab strip inside the clip looks the
right width while answering on only half of it.

**How to access:** the inspector's own width bounds are
`InspectorState.minWidth` / `defaultWidth` / `maxWidth`; the floor reserved for
the detail area beside it belongs to the other side of the divider and lives as
`WorkspaceDetailView.minDetailWidth`. The live
width is a per-workspace `@State` in `WorkspaceDetailView`, seeded on
`.onAppear` (re-seeded per workspace because the detail view carries a
per-workspace `.id`) and persisted **on drag-end only** via
`AppModel.setInspectorWidth(_:for:)` (clamped, debounced). `InspectorPanel` does
not measure its own width — it fills whatever `.frame(width:)` it is given.
