---
name: "Real in-process GhosttySurfaceView e2e test harness"
description: "How to drive a real keyDown -> interpretKeyEvents -> libghostty -> shell round trip in XCTest, and its timing gotcha"
type: reference
---

# Real in-process GhosttySurfaceView e2e test harness

To test real keyboard-dispatch behavior (`keyDown` → `interpretKeyEvents` →
libghostty → PTY shell) end to end in XCTest, without OS Accessibility permission and
without the debug-channel bypass (`casper debug send-key` calls `ghostty_surface_key`
directly, skipping `keyDown`/`interpretKeyEvents` entirely — it cannot exercise this
class of bug, see [[ghostty-option-as-alt]]):

1. Use a real (non-`.forTesting()`) `GhosttyRuntime()` — `.forTesting()` has `app =
   nil` and never creates a surface.
2. Build `GhosttySurfaceView(runtime:configuration:)`, assign it as
   `window.contentView` on a real (can be `.borderless`, off-screen-sized fine)
   `NSWindow` — this triggers `viewDidMoveToWindow` → real `ghostty_surface_new`.
3. Poll `view.surface != nil` for up to ~10s on the RunLoop; `throw XCTSkip(...)` if it
   never appears (the documented [[e2e-surface-creation-flakiness]], environmental).
4. `window.makeFirstResponder(view)`, then call `view.keyDown(with:)` directly with a
   synthetic `NSEvent` — this is a genuine Swift method call, not synthetic OS input,
   so it needs no Accessibility permission and exercises the real `doCommand`/
   `insertText`/`interpretKeyEvents` dispatch.
5. Seed/read content via `surface.sendText(...)` / `surface.readText(scrollback:
   false)`.

**Critical timing gotcha**: the spawned PTY shell needs real settle time before it is
interactively ready (ZLE/readline actually attached in raw mode). Too short a wait (or
a "poll until text looks non-empty/stable" loop) reads back **kernel cooked-mode
echo** instead of real shell behavior — every control character echoes literally as
`^X` in that window regardless of whether the real shell would handle it, producing a
false bug signal (this happened during the AZERTY Ctrl-A investigation: an
under-settled harness made even the already-fixed QWERTY case look broken). The
working, reproducible recipe: pump the RunLoop for a **fixed** `settle(0.6)` right
after the surface appears, then `settle(0.4)` after each subsequent input step
(`RunLoop.current.run(until: Date().addingTimeInterval(seconds))`). A
"wait-until-stable" polling loop was flakier than this fixed-pump approach in this
investigation — prefer the fixed settle times over adaptive polling here.

See `Tests/CasperGhosttyTests/GhosttyEditingCommandReplayTests.swift` for the
canonical example (`settle(_:)` helper + `assertControlAMovesToLineStart(keyCode:)`).
