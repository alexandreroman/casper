---
name: "WindowFloor resizes the window"
description: "WindowFloor.apply can setFrame the window, so a per-frame metrics publish makes the window chase the drag"
type: project
---

# WindowFloor resizes the window

`WindowFloor.apply` does more than write `minSize`/`contentMinSize`: it calls
`grow(_:toAtLeast:)`, which ends in `window.setFrame(_:display:)` whenever the
content is narrower than the floor. The floor's width is
`sidebarWidth + inspectorSlice + terminalMinimumSize`, and `inspectorSlice`
comes straight from the inspector's live width.

So any source that republishes `terminalHostMetrics` once per frame resizes the
window once per frame. On a window already resting at its floor, dragging the
inspector divider wider raises the floor above the current content width on
every frame, `grow` fires, and the window chases the pointer rightwards at
~60 fps.

**Why:** the floor is a constraint *and* an action. Treating `apply` as a cheap
setter is what makes the window move on its own.

**How to apply:** a per-frame geometry source must defer its publish to the end
of the interaction — `WorkspaceDetailView` gates `publish(_:)` on an
`isDraggingInspector` flag and publishes once in `SplitterHandle`'s `onCommit`.
The floor is never dropped meanwhile: `WindowConfigurator`'s
`didUpdateNotification` observer keeps re-applying the last published value.
Genuine geometry changes (window resize, workspace switch, inspector collapse)
publish immediately. See [[swiftui-inspector-width]].
