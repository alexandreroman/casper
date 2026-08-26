---
name: "Surface focus is first responder AND window key"
description: "AppKit sends no resignFirstResponder on key loss, so the caret needs the window's key notifications"
type: reference
---

# Surface focus is first responder AND window key

The focus state pushed into libghostty (`ghostty_surface_set_focus`) drives the
caret shape: solid when focused, hollow when not. A native terminal — upstream
Ghostty included — draws a hollow caret while its window is inactive, so the
pushed state is the AND of two inputs in `GhosttySurfaceView`:

- AppKit first-responder status (`becomeFirstResponder` /
  `resignFirstResponder`, plus the explicit `blurForLayoutChange()`),
- the hosting window's key status, tracked through per-window
  `NSWindow.didBecomeKeyNotification` / `didResignKeyNotification` observers
  registered in `updateWindowObservers()`.

The window half is load-bearing: AppKit sends **no** `resignFirstResponder` when
a window merely stops being key — the view remains that window's first
responder — so a responder-only focus model renders a solid caret in an
inactive window. `ghostty_app_set_focus` (wired in `AppDelegate`) governs
cursor blink only and never changes the caret shape.

Key notifications carry the transition, so the handlers derive the state from
which notification fired rather than reading `window.isKeyWindow` back. Entering
or leaving a window fires no notification, so `updateWindowObservers()` re-syncs
the flag from `window?.isKeyWindow ?? false`; a view with no window is a
detached cached surface and is never focused (it is marked occluded for the same
reason).

Unlike occlusion, focus pushes are **not** de-duplicated: libghostty's focus
state for a freshly created surface is undefined, and `blurForLayoutChange()`
and `AppModel.focusSurfaceViewIfActive` rely on their push landing
unconditionally. A successful `createSurfaceIfNeeded()` reconciles focus the
same way it reconciles occlusion, because creation can land after the responder
transition whose push went to a nil surface.

Headless tests drive the key state by posting the notifications on an offscreen
borderless `NSWindow`; `makeKeyAndOrderFront` does not take in a test runner.
