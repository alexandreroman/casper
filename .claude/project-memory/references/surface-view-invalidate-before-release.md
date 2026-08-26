---
name: "A surface view is invalidated before its last reference is dropped"
description: "GhosttySurfaceView.invalidate() frees the libghostty surface while the view is still alive, closing a use-after-deinit window"
type: reference
---

# A surface view is invalidated before its last reference is dropped

Teardown of a terminal pane is reference-driven: `AppModel.discardSurfaceViews`
drops its reference to a `GhosttySurfaceView`, the view deallocates, and its
stored `surface` is released *after* `deinit` returns — which is what triggers
`ghostty_surface_free`. Anything libghostty emits from inside that free (an
action, `close_surface_cb`) reaches `surfaceView(from:)` or
`clipboardView(from:)` in `GhosttyRuntime`, which recover the view with
`takeUnretainedValue()` on the stored `userdata` pointer. At that point the
view is mid-deallocation.

`GhosttySurfaceView.invalidate()` closes the window: it nils `surface`, so the
free happens while the view is still fully alive and every trampoline resolves a
valid object. It is idempotent, and `AppModel.discardSurfaceViews` calls it on
each view before releasing the reference.

This is a cross-module invariant with no compiler enforcement — an edit to
`discardSurfaceViews` that drops the `invalidate()` call opens the window
silently, and the residual is narrow enough that tests are unlikely to catch it.
Keep the call whenever surface views are torn down, including any new teardown
path. See also [[persistent-nsview-host-sharing]] and [[surface-identity]].
