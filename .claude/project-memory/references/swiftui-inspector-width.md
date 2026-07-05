---
name: "Custom resizable inspector panel"
description: "Why Casper hand-rolls the inspector panel instead of SwiftUI's native .inspector, and how it resizes"
type: reference
---

# Custom resizable inspector panel

Casper's inspector is a **hand-rolled side panel**, not SwiftUI's native
`.inspector`. It lives in `Sources/CasperUI/WorkspaceDetailView.swift`
(`InspectorPanel` renders the content): a plain `HStack` of the detail area, a
self-drawn draggable divider, and `InspectorPanel` pinned via `.frame(width:)`.

**Why not the native `.inspector`:** on macOS 26 it **aborts the instant its
divider is dragged**. The AppKit-hosted `SplitViewChildController` reports a
changed hosted-content min/max mid-pass and re-invalidates the window's
constraints, looping until AppKit exceeds its budget (`NSException`: "more
Update Constraints in Window passes than there are views in the window",
thrown from `-[NSSplitView mouseDown:]`). This is a pre-existing framework bug;
the native inspector resize had never been exercised interactively on macOS 26.
The native inspector also never reported the user-resized width back (no
`Binding` overload of `inspectorColumnWidth`; feeding a live-measured width into
`.inspectorColumnWidth(ideal:)` was itself reentrant and fragile). Moving the
inspector out of the `NavigationSplitView`'s `NSSplitView` into a pure SwiftUI
`HStack` removes the `SplitViewChildController` from the path entirely, so the
divider is a normal SwiftUI gesture that cannot trigger the loop.

**Open/close animation — reveal by clip width, do NOT mount/unmount with a
`.move` transition.** The panel is **always mounted**; collapsing animates a
**trailing-pinned clip width** (`0 ↔ divider+panel`, `alignment: .trailing` +
`.clipped()`) so the panel content sits at fixed coordinates and is *revealed*,
not translated. A `.transition(.move(edge: .trailing))` looked right but made
the **segmented tab `Picker` lag** the sliding chrome: it is an AppKit
`NSSegmentedControl`, and AppKit-hosted views don't follow a SwiftUI
transition's per-frame offset (a freshly inserted `NSView` is laid out straight
at its final frame). This mirrors `SplitContainerView`, which animates hosted
Metal views by frame/offset on always-mounted views for the same reason. Because
the panel now stays mounted while collapsed, `InspectorPanel` **gates its heavy
`content`** (the diff / browser views) on the expanded state, so no diff
computation or `WKWebView` runs while collapsed. Trailing (not leading)
alignment is load-bearing: the detail area is `maxWidth: .infinity`, so the
inspector's *right* edge is fixed and its *left* edge moves — leading alignment
would translate the tabs and reintroduce the lag.

**Divider drag — track the pointer by ABSOLUTE location** (the same principle as
`SplitContainerView`'s splitter, which maps absolute movement rather than
accumulated translation — though that one now drives its drag from AppKit): the
inspector's `DragGesture` reads `value.location.x` in a
stable **named coordinate space** anchored to the full-width container
(`.coordinateSpace(.named(...))` on the `HStack`), and sets
`inspectorWidth = total - location.x`. Using accumulated `translation.width`
instead **lags/jitters**, because the divider is an `HStack` child that shifts as
the panel resizes, so the gesture's local origin moves under the cursor.

**Why:** both facts are non-obvious and were each paid for with a live debug
session — the crash is a silent framework limitation, and the translation-based
drag looks correct but feels laggy.

**How to access:** width bounds are `InspectorState.minWidth` /
`defaultWidth` / `maxWidth` (plus a `minDetailWidth` floor kept for the detail
area). The live width is a per-workspace `@State` in `WorkspaceDetailView`,
seeded on `.onAppear` (re-seeded per workspace because the detail view carries a
per-workspace `.id`) and persisted **on drag-end only** via
`AppModel.setInspectorWidth(_:for:)` (clamped, debounced). `InspectorPanel` no
longer measures its own width — it fills whatever `.frame(width:)` it is given.
