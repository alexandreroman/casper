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
  `GhosttySurfaceView` pointer (same value as `nsview`), so the callbacks
  recover the view with
  `Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()`.
- These three clipboard callbacks fire on the **main thread** — safe to touch
  `NSPasteboard` and call `ghostty_surface_complete_clipboard_request` inside
  `MainActor.assumeIsolated { ... }`, no `DispatchQueue.main.async` hop needed.
- **Request contract.** `read_clipboard_cb` returns a
  `ghostty_clipboard_read_result_e`; `STARTED` obliges exactly one later
  `ghostty_surface_complete_clipboard_request` *or*
  `ghostty_surface_deny_clipboard_request` on its `state`, and every
  `confirm_read_clipboard_cb` call carries the same obligation. Casper always
  answers `STARTED`, even with nothing to serve: core never replies to an OSC
  52 read reported `UNAVAILABLE`, so the asking program would wait forever.
  The read callback cannot tell an OSC 52 read from a paste or a kitty read,
  so the same answer has two side effects: a `performable:` paste binding
  counts as performed on an empty clipboard, and a kitty read with nothing
  servable reaches the `KITTY_READ` gate with an empty preview instead of
  core's unprompted "no representations" reply. Both are invisible while the
  gates approve unconditionally; an active prompt would surface the second.
- **Clipboard data is pointer-plus-length.** `ghostty_clipboard_content_s.data`
  is binary-safe and not NUL-terminated: copy exactly `len` bytes
  (`GhosttyClipboardContent`), never `String(cString:)`, which over-reads. Only
  the `mime` strings are C strings. A write can carry several representations
  (plain text plus HTML), so Casper picks the plain-text entry by MIME, not the
  first one.
- **Borrowed memory.** The contents in `ghostty_clipboard_confirm_s` live only
  for the callback, so they are copied before any hop; the pointers handed to
  `ghostty_surface_complete_clipboard_request` must stay valid for the whole
  call, including a `confirm_read_clipboard_cb` core fires synchronously from
  inside it, and are free to release once it returns
  (`GhosttySurface.completeClipboardRequest` owns C copies for that span, as
  upstream's `Ghostty.App.completeClipboardRequest` does).
- **Request kinds reaching `confirm_read_clipboard_cb`:** `PASTE` (paste
  protection), `OSC_52_READ`, `KITTY_READ`, `KITTY_WRITE`. A kitty write never
  calls `read_clipboard_cb`; once confirmed, core delivers it to
  `write_clipboard_cb` as a trusted write. Casper serves and writes plain text
  only.

**Binding action names** (via `ghostty_surface_binding_action`, used by
`casper debug send-action <name>`): `paste_from_clipboard`, `copy_to_clipboard`,
`select_all` (no argument). Font-size actions take a `:<amount>` suffix:
`increase_font_size:1`, `decrease_font_size:1`, `reset_font_size` (no argument);
one step moves a default-configuration cell from 17×37 px to 18×40 px. Verify a
font-size action by watching `cellWidthPixels`/`cellHeightPixels` in
`casper debug dump-state` change around each `send-action`.

**Swift 6 strict-concurrency gotcha:** passing a raw `UnsafeMutableRawPointer?`
function parameter directly into a `MainActor.assumeIsolated { ... }` closure
from a nonisolated function fails with
`sending 'state' risks causing data races [#SendingRisksDataRace]`, even though
the closure runs synchronously. Fix (the same pattern `casperGhosttyWakeup` uses
to cross into `DispatchQueue.main.async`): convert the pointer to a trivial
`UInt` bit-pattern *before* entering the closure, then reconstruct
`UnsafeMutableRawPointer(bitPattern:)` inside it. See
`casperGhosttyReadClipboard`/`casperGhosttyConfirmReadClipboard` in
`Sources/CasperGhostty/GhosttyRuntime.swift`.

**Swift 6 stored-closure gotcha:** a closure *property* on a `@MainActor` type
must carry `@MainActor` in its own **type**
(`static var approveUntrusted: @MainActor (String) -> Bool`), or assigning a
main-actor-isolated function as its default is rejected with *converting
function value ... loses global actor 'MainActor'* — the type's isolation does
not flow into the closure type. Call sites that substitute another closure
annotate their parameter the same way (`@escaping @MainActor (String) -> Bool`).
See [[osc52-clipboard-write-policy]].
