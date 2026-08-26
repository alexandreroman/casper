---
name: "libghostty mouse handling parity"
description: "Core-side multi-click, tracking-area position stream, and surface-scoped mouse-shape/visibility action routing in the pinned libghostty"
type: reference
---

# libghostty mouse handling parity

Confirmed against the pinned header (`Vendor/ghostty/ghostty.h`, Ghostty v1.3.1)
while bringing `GhosttySurfaceView` to upstream mouse parity.

- **Multi-click is entirely core-side.** `ghostty_surface_mouse_button(surface,
  state, button,
  mods)` has **no click-count parameter**: double-click (word) and triple-click
  (line) selection are detected inside libghostty from timing plus position in
  the continuous `ghostty_surface_mouse_pos` stream. Consequence: the view must
  feed that stream via an NSView tracking area (`updateTrackingAreas` with
  `[.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect,
  .activeAlways]`), or a
  fresh click lands at a stale cell and word/line selection cannot work. There
  is nothing to "enable" on the C side — position tracking alone fixes it.

- **`ghostty_surface_mouse_button` button mapping** from `NSEvent.buttonNumber`:
  0→`GHOSTTY_MOUSE_LEFT`, 1→`GHOSTTY_MOUSE_RIGHT`, 2→`GHOSTTY_MOUSE_MIDDLE`,
  3→`GHOSTTY_MOUSE_FOUR`, 4→`GHOSTTY_MOUSE_FIVE` (`GHOSTTY_MOUSE_UNKNOWN` for
  the rest). Middle-click paste is handled by the core once the button is
  forwarded.

- **Scroll modifiers** — `ghostty_input_scroll_mods_t` is `typedef int` with an
  undocumented packed bit layout; `scrollWheel` sets both the precision bit and
  the momentum phase. See [[ghostty-scroll-mods-layout]] for the layout and why
  the precision bit is mandatory. Alongside it, `scrollingDeltaX/Y` is doubled
  when `event.hasPreciseScrollingDeltas` (trackpad deltas arrive at ~half the
  magnitude of wheel deltas).

- **The resting I-beam is the app's default, NOT a libghostty action.**
  libghostty emits `GHOSTTY_ACTION_MOUSE_SHAPE` only to *change* the shape
  (pointing-hand over a link, resize handles, or
  `GHOSTTY_MOUSE_SHAPE_DEFAULT`/arrow in mouse-reporting mode). It never emits a
  `text` shape for the normal cursor over the grid — injecting mouse positions
  produces zero shape actions. Upstream defaults its pointer to
  `.horizontalText`, so `GhosttySurfaceView` must default its cursor to
  `NSCursor.iBeam` (`private var lastCursor: NSCursor = .iBeam`) and let shape
  actions override it; waiting for a `text` action leaves the arrow forever.
  Apply the cursor via AppKit's own hook — `cursorUpdate(with:)` (needs the
  `.cursorUpdate` tracking-area option) plus a re-apply on `mouseEntered` —
  because `MOUSE_SHAPE` is delivered asynchronously (wakeup→tick→`action_cb`)
  and a bare `NSCursor.set()` gets clobbered by AppKit's cursor-rect reset on
  the next move.

- **Mouse-shape and mouse-visibility are surface-scoped actions**, delivered
  through `action_cb`'s `ghostty_target_s` (tag `GHOSTTY_TARGET_SURFACE`), NOT
  the app-level `onAction` closure. Recover the owning `GhosttySurfaceView` from
  `ghostty_surface_userdata(target.target.surface)` — the **same** per-surface
  userdata (the view pointer) the clipboard callbacks use (see the
  `ghostty-clipboard-callbacks` note). `casperGhosttyAction` handles
  `GHOSTTY_ACTION_MOUSE_SHAPE` (`action.action.mouse_shape`) and
  `GHOSTTY_ACTION_MOUSE_VISIBILITY` (`action.action.mouse_visibility`, values
  `GHOSTTY_MOUSE_VISIBLE`/`GHOSTTY_MOUSE_HIDDEN`) directly, inside
  `MainActor.assumeIsolated`, and returns before the runtime's `handleAction`.
  `GHOSTTY_ACTION_MOUSE_OVER_LINK` is another surface-scoped action that would
  use the same recovery path if implemented later.
