---
name: "e2e headless key-window limitation"
description: "This automation environment cannot grant a launched Casper window real OS-level key/frontmost status, blocking e2e checks for NSApp.keyWindow-dependent code"
type: reference
---

# e2e headless key-window limitation

Confirmed during kbd-final-fixes (⌘W close-window fix): this Claude Code
automation environment cannot give a background-launched `casper` GUI process
genuine OS-level focus, even though the process is a normal
`NSApplicationActivationPolicy.regular` app that appears in the Dock and
`System Events`' process list.

Evidence gathered in one session:
- `screencapture -x` fails with `could not create image from display`, even
  right after `caffeinate -u -t 60 &` and confirming via `system_profiler
  SPDisplaysDataType` that no display reports `Display Asleep`.
- `osascript -e 'tell application "System Events" to set frontmost of
  process "casper" to true'` returns success with no error, but a follow-up
  `get frontmost of process "casper"` still reports `false`.
- Clicking the app's own Dock icon via `System Events` UI scripting
  (`click UI element "casper" of list 1`) also succeeds without error but
  does not change which process is frontmost.
- Meanwhile, `casper debug screenshot` (libghostty's own internal Metal
  capture, not `screencapture`) works fine — the app is alive, rendering,
  and has a live surface (`casper debug dump-state` reports `"focused":
  true`, i.e. `window?.firstResponder === view`).

Net effect: any code path gated on `NSApp.keyWindow` (e.g. closing the
window on ⌘W/close-tab/close-window actions via
`NSApp.keyWindow?.performClose(nil)`) cannot be driven to a visible
end-to-end result here, because `NSApp.keyWindow` stays `nil` regardless of
launch recipe, caffeinate, or focus-stealing attempts. This is a different
failure mode than the already-documented `ghostty_surface_new` nulls (see
the "e2e surface creation flakiness" note) — the surface and app-level action
dispatch work fine and can be confirmed via `log stream` (the
`GhosttyRuntime.handleAction` → `LoggingActionHandler` → `onAction` chain
fires and logs as expected); only the final AppKit-level `keyWindow`-gated
step is unverifiable end-to-end.

**When this happens:** verify via `log stream --predicate 'subsystem ==
"com.github.alexandreroman.casper"' --level debug --style compact` that the
decoded action reaches the intended `onAction` case (proves the C→Swift
plumbing), then fall back to source-level reasoning for anything gated on
`NSApp.keyWindow`/real OS focus, and say so explicitly in the report rather
than claiming an unobserved termination.
