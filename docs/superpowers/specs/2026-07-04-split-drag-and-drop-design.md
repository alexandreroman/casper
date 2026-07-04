# Split drag-and-drop — design

Reproduce Ghostty's drag-and-drop split relocation inside Casper, and make the
existing pane right-click split menu actually appear on terminal panes.

The macOS split UI of Ghostty is written in SwiftUI/AppKit, so its model is
directly transposable. This design mirrors Ghostty's interaction faithfully and
adapts the tree mutation to Casper's own `LayoutNode` (an N-ary tree, versus
Ghostty's binary `SplitTree`).

## Reference: what Ghostty does

From `macos/Sources/Features/Splits/` in `ghostty-org/ghostty`:

- **Drag handle** — a small "3-dot" grip overlay on each split pane, revealed
  **only on hover** (PR #10280; the earlier always-visible bar was disliked).
- **Drag payload** — a `Transferable` carrying the surface id under a private
  `UTType` (`.ghosttySurfaceId`); a thumbnail follows the cursor.
- **Drop zones** — `enum TerminalSplitDropZone { top, bottom, left, right }`.
  Zone = nearest edge to the cursor (triangular regions). **No center/swap
  zone.** A move is remove-source + reinsert-beside-target.
- **Drop delegate** — a custom `DropDelegate` per pane reads `DropInfo.location`
  to compute the zone, drives an overlay highlight, and on `performDrop`
  dispatches a `.drop(payload, destination, zone)` action.
- Dropping on the source itself is a no-op. (Ghostty also allows dropping onto
  the titlebar/tab bar to spawn tabs/windows — **out of scope**: Casper has no
  equivalent tab/window model, only sidebar workspaces.)

## Interaction model (Casper)

- Each **leaf** pane gets a 3-dot grip overlay on its top edge, shown only on
  hover, hidden when the workspace has a single pane (nothing to rearrange).
- Press-drag on the grip starts the drag; a lightweight preview (pane icon +
  cwd label) follows the cursor. A true live snapshot is out of scope — the
  Metal `CAMetalLayer` view is not trivially snapshottable and a light preview
  is enough (YAGNI).
- Hovering another pane highlights one of the 4 edge zones (nearest-edge). Drop
  moves the dragged pane to that side of the target. Drop on source = no-op;
  drop outside any pane = cancel.

## Mechanism

Ghostty's grip is **not** a SwiftUI `.draggable` — it is an **AppKit NSView**
layered above the surface (see `SurfaceGrabHandle.swift` / `SurfaceDragSource.swift`).
A SwiftUI `.draggable` overlay would lose the mouse-down to the Metal surface
NSView underneath (it hit-tests in front); a sibling NSView in the ZStack
hit-tests correctly in front. Casper mirrors this exactly:

- **Source (AppKit)** — `PaneDragHandleView: NSView` wrapped in an
  `NSViewRepresentable`, placed in a `ZStack` above the pane content, pinned to
  the top. Full pane width × a short top band (hover), but `hitTest` returns
  `self` only inside the centered ~80×12 handle rect and `nil` elsewhere, so
  clicks outside the handle fall through to the terminal. A tracking area over
  the band toggles hover (reveals a faint "ellipsis" glyph). It overrides
  `acceptsFirstMouse` → true and `mouseDown` (no `super`, so no window drag); on
  `mouseDragged` it calls `beginDraggingSession` with an `NSPasteboardItem`
  carrying `Surface.id` under a private `UTType` (`com.casper.surface-id`) and a
  lightweight drag image (icon + cwd — not a live Metal snapshot). It conforms
  to `NSDraggingSource` returning `.move`, with an escape-to-cancel monitor.
- **Target (SwiftUI)** — `.onDrop(of: [.casperSurfaceID], delegate:)` on a
  `Color.clear` background of the pane. The `DropDelegate` stores the pane size,
  reads the dragged `Surface.id` from the item provider, ignores a self-drop,
  computes the zone from `DropInfo.location`, publishes it to a `@State` overlay,
  and on `performDrop` calls `AppModel.moveSurface(sourceID:toTarget:zone:)`.
- **Highlight** — a translucent SwiftUI overlay over the active half. It is
  SwiftUI chrome above the terminal, not a second Metal view, so it does not hit
  the Metal-overlap constraint.

## Tree mutation (CasperCore — pure, tested)

New op in `LayoutTree`:

```
static func move(_ tree: LayoutNode, surfaceID: UUID, toTarget: UUID,
                 direction: GhosttySplitDirectionLike) -> (LayoutNode, focus: UUID)?
```

Semantics: **remove** the source leaf (reusing `closeSurface`'s removal +
single-child collapse), then **reinsert the same `Surface` value verbatim**
(same id) beside the target, using the existing `split` insertion logic with
orientation/side from `orientationAndSide(for:)`. Returns `nil` when the move is
degenerate (source == target, or source/target missing).

- `Surface.id` is preserved, so the cached `GhosttySurfaceView`/PTY survives
  (the `surface-identity` invariant). No new surface is minted.
- Ratios are re-evened by `split`. Removing the source may collapse a 2-child
  split — handled by the existing removal path. Target survives removal because
  it differs from source; locate/insert against the reduced tree.

New pure helper, mirroring Ghostty's `calculate`:

```
enum DropZone { case top, bottom, left, right }
static func dropZone(at point: CGPoint, in size: CGSize) -> DropZone
```

`AppModel.moveSurface(sourceID:toTarget:zone:)` wraps the op: writes `layout`,
keeps focus on the moved surface, `persist()`, re-anchors the first responder —
mirroring `insertSurfaceBySplitting`.

## Part 2 — right-click split menu on terminal panes

The pane menu (four splits + copy/paste + close) already exists in
`SurfaceHostView` as a SwiftUI `.contextMenu`, but likely never fires on a
terminal pane because `GhosttySurfaceView.rightMouseDown/Up` forwards the event
to libghostty.

1. **Verify** the bug first with the `debug-casper` skill (right-click a
   terminal pane; confirm no menu).
2. **Fix**: in `GhosttySurfaceView`, present the pane menu when the terminal is
   not consuming the right-click (mouse-reporting inactive); otherwise forward
   to libghostty as today. Reuse the same `AppModel` split/close actions so the
   menu stays defined once.

## Testing

- **CasperCore unit tests** (style of `LayoutTreeTests`): `move` in all four
  directions; collapse of a 2-child split on removal; no-op on source == target;
  N-ary flatten cases; `Surface.id` preserved; ratios re-evened. Pure
  `dropZone(at:in:)` for each region incl. diagonal ties.
- **Manual (debug build)**: grip appears on hover only; drag preview; zone
  highlight tracks cursor; drop relocates the pane; PTY survives
  (`casper debug dump-state` reports the same surface count); right-click menu
  appears on a terminal pane.

## Files

- `Sources/CasperCore/LayoutTree.swift` — `move`, `DropZone`, `dropZone`.
- `Sources/CasperUI/PaneDragAndDrop.swift` (new) — `Transferable` payload,
  `DropDelegate`, zone→overlay, grip handle view.
- `Sources/CasperUI/SurfaceHostView.swift` — attach grip + drop + overlay.
- `Sources/CasperUI/AppModel.swift` — `moveSurface`.
- `Sources/CasperGhostty/GhosttySurfaceView.swift` — right-click menu fix.
- `Tests/CasperCoreTests/LayoutTreeTests.swift` — new cases.

## Out of scope

- Dropping onto a titlebar/tab bar to create tabs or windows (no Casper analog).
- Dragging a whole sub-split (only leaf panes are draggable).
- A live terminal snapshot as the drag preview.
- Center/swap drop zone (Ghostty has none).
