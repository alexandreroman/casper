---
name: "Off-screen host windows stay out of the on-screen list"
description: "Ordering a window parked at -100_000 breaks Mission Control; off-screen hosts are never ordered in"
type: project
---

# Off-screen host windows stay out of the on-screen list

Casper hosts views that must lay out and run without being visible in borderless
`NSWindow`s parked far off-screen at `(-100_000, -100_000)`:

- `AppModel.makeBackgroundSurfaceNursery()` — the background surface nursery
  (see [[background-surface-nursery]]).
- `BrowserCapture.snapshot(url:width:height:)` — the one-shot `WKWebView`
  capturer.

Test host windows follow the same rule, and **ordering is the whole rule** —
neither the origin nor the style mask. `AppModelTests`, `RealSurfaceHarness`,
`GhosttyFocusCallbackTests` and `BrowserSurfaceViewTests` build their hosts at
the default `(0, 0)` and are safe purely because none of them is ever ordered
in; `WorkspaceInfoPanelTests` parks its host at `-100_000` as well, and keeps a
`.titled` mask because the panel geometry it asserts on is measured against that
mask. An *ordered* host is what pops a real window into the developer's desktop
for the length of a test method — at `(0, 0)` it flashes in the bottom-left
corner, and at `-100_000` it takes Mission Control down with it.

**These windows are never ordered on-screen** — no `orderFrontRegardless()`, no
`orderFront(_:)`. Mission Control lays out *every* window the WindowServer
reports as on-screen, so an ordered window at -100_000 stretches the layout
bounding box to ~101,000 px and every real window is scaled down to nothing: the
three-finger swipe-up gesture visibly breaks, with all windows receding and
vanishing instead of showing thumbnails. A window that is never ordered in is
absent from the on-screen list and therefore invisible to Mission Control, while
remaining a perfectly valid `view.window` host.

**Why hosting still works without ordering:**

- `GhosttySurfaceView.viewDidMoveToWindow()` / `createSurfaceIfNeeded()` gate
  only on `window != nil`, which `addSubview` satisfies regardless of window
  visibility. Same for `WKWebView` layout and `takeSnapshot`.
- Hosted surfaces take their dimensions from an explicit
  `view.frame = host.bounds`, not from the window being displayed.
- `pushDisplayID()` no-ops because `window?.screen` is nil off any display.
- `occlusionState` on a non-visible window lacks `.visible`, so surfaces read as
  occluded and libghostty keeps their render thread paused while the PTY runs.
- An unordered window can never become key, so it cannot steal keyboard focus.

**What does not work off-display: `requestAnimationFrame`.** A `WKWebView` in a
window on no display never gets an animation-frame callback, because the
WindowServer drives rAF from a display's refresh cycle. Any JavaScript readiness
signal that ends in a paint barrier therefore hangs forever and silently burns
whatever outer timeout bounds it. `BrowserCapture.waitForFullRender` races the
two-frame barrier against a ~120 ms `setTimeout` fallback for exactly this
reason: a visible window still waits for a real paint, an off-display one
proceeds after two frames' worth of slack. Measured on a page with a 600 ms
webfont and image: 5026 ms → 124 ms, byte-identical snapshot pixels — the
barrier contributes latency only. `document.fonts.ready`, image `load`/`error`
events and `document.readyState` do fire off-display, so they stay unraced.

**How to diagnose** a regression here: dump
`CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` and look for
an entry with `layer=0`, `alpha=1.0` and a hugely negative `x` — that is an
off-screen host that leaked into the on-screen list.
