---
name: "libghostty clipboard callbacks"
description: "userdata/thread contract for libghostty's clipboard callbacks, and the binding action names for copy/paste/select-all and font size"
type: reference
---

# libghostty clipboard callbacks

- The `void* userdata` libghostty passes to `read_clipboard_cb`,
  `confirm_read_clipboard_cb`, and `write_clipboard_cb` is the **per-surface**
  `userdata` set in `ghostty_surface_config_s` (via
  `GhosttySurfaceConfiguration.withCValue`), not the app-level
  `ghostty_runtime_config_s.userdata`. Casper sets it to the hosting
  `GhosttySurfaceView` pointer (same value as `nsview`), so the callbacks recover
  the view with
  `Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()`.
- These three clipboard callbacks fire on the **main thread** — safe to touch
  `NSPasteboard` and call `ghostty_surface_complete_clipboard_request` inside
  `MainActor.assumeIsolated { ... }`, no `DispatchQueue.main.async` hop needed.

**Binding action names** (via `ghostty_surface_binding_action`, used by
`casper debug send-action <name>`): `paste_from_clipboard`, `copy_to_clipboard`,
`select_all` (no argument). Font-size actions take a `:<amount>` suffix:
`increase_font_size:1`, `decrease_font_size:1`, `reset_font_size` (no argument);
one step moves the demo's default cell from 17×37 px to 18×40 px. Verify a
font-size action by watching `cellWidthPixels`/`cellHeightPixels` in
`casper debug dump-state` change around each `send-action`.

**Swift 6 strict-concurrency gotcha:** passing a raw `UnsafeMutableRawPointer?`
function parameter directly into a `MainActor.assumeIsolated { ... }` closure from
a nonisolated function fails with `sending 'state' risks causing data races
[#SendingRisksDataRace]`, even though the closure runs synchronously. Fix (the same
pattern `casperGhosttyWakeup` uses to cross into `DispatchQueue.main.async`):
convert the pointer to a trivial `UInt` bit-pattern *before* entering the closure,
then reconstruct `UnsafeMutableRawPointer(bitPattern:)` inside it. See
`casperGhosttyReadClipboard`/`casperGhosttyConfirmReadClipboard` in
`Sources/CasperGhostty/GhosttyRuntime.swift`.
