---
name: "SwiftUI native inspector width persistence"
description: "The .inspector column width is scene-level; how Casper persists it per workspace"
type: reference
---

# SwiftUI native inspector width persistence

SwiftUI's native `.inspector(isPresented:)` column width is **scene-level**:
one width is retained per `NavigationSplitView` and carried across whatever
content the detail shows. There is **no** `Binding` overload of
`inspectorColumnWidth` — `(min:ideal:max:)` seeds only the INITIAL width, and
SwiftUI never reports the user-resized width back. Worse, measuring the panel
with a `.background(GeometryReader { … .preference(…) })` + `.onPreferenceChange`
does **not** work: across the AppKit-hosted `NSSplitView`, the preference only
ever delivers the key's default value (observed live as `raw=0`, then clamped to
the min and wrongly persisted).

Casper's working recipe (see `Sources/CasperUI/InspectorPanel.swift`,
`WorkspaceDetailView.swift`, `RootView.swift`, and `InspectorState` in
`Sources/CasperCore/Models.swift`):

- **Measure** with `.onGeometryChange(for: CGFloat.self, of: { $0.size.width })`
  on the panel's own root view (macOS 15+). This reads the resolved layout
  width the same way a root `GeometryReader` proxy did, but without the wrapper.
  Not a `.background`, not a `PreferenceKey`. (Earlier code used a root
  `GeometryReader` + `.onChange(of: proxy.size.width)` as a macOS 14 fallback;
  dropped once the deployment target became macOS 15.)
- **Restore** by feeding the persisted per-workspace width into
  `.inspectorColumnWidth(ideal:)`.
- **Re-seed per workspace on switch** with `.id(workspaceID)` on the detail
  view — otherwise the scene-level width leaks across workspaces and the
  measurement clobbers the other workspace's saved value.

**Why:** these are non-obvious SwiftUI limitations that cost a live
debugging session (the app's `debug` channel + AppleScript sidebar clicks) to
pin down; the preference approach looks correct but silently fails.

**How to access:** the per-workspace width lives in `InspectorState.width`
(bounds: `InspectorState.minWidth`/`defaultWidth`/`maxWidth`), clamped and
debounced through `AppModel.setInspectorWidth(_:for:)`. To verify width
behaviour in the running debug build, drive workspace switches with AppleScript
System Events clicks on the sidebar `outline` rows (the `casper debug` channel
has no workspace-switch verb).
