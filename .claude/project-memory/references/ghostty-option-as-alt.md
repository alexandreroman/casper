---
name: ghostty-option-as-alt
description: "macos-option-as-alt wiring status, and the pinned libghostty binary's unconfirmed behavior for it"
type: reference
---

# ghostty-option-as-alt

`GhosttySurfaceView.keyDown` calls `ghostty_surface_key_translation_mods(surface,
rawMods)` before `interpretKeyEvents`, and strips `.option` from the event Cocoa
sees (via `ghosttyTranslationEvent` in `GhosttyInput.swift`) whenever libghostty's
answer omits the Alt bit — this is the documented mechanism real Ghostty's macOS
app uses for `macos-option-as-alt`, and matches the reference AppKit key handler
vendored in `.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/Platform/
AppKit/TerminalKeyEventHandler@AppKit.swift` (not a Casper dependency — read for
reference only).

**Unconfirmed in the pinned binary**: end-to-end testing (real `NSEvent`-driven
Option keypresses via AppleScript `System Events`, which exercises the true
`keyDown`/`interpretKeyEvents` path — the debug `send-key` channel does NOT,
since it calls `ghostty_surface_key` directly) showed `ghostty_surface_key_
translation_mods` returning the Alt bit unchanged for a plain Option+letter
combo, identically under the default config and a scratch config with
`macos-option-as-alt = true`. Option composed a special character in both
cases; the config's effect on this API's answer was not observed for this
pinned libghostty binary (Lakr233/libghostty-spm 1.2.8 = Ghostty v1.3.1).

Also confirmed independently: when a key event sent to `ghostty_surface_key`
carries non-nil `text`, libghostty inserts it verbatim regardless of `mods`/
`consumed_mods` — the ESC-prefixed Meta-encoding path only runs for text-less
key events. This explains why the debug `send-key --mods opt` path can never
demonstrate Meta-b (it always attaches `text`), independent of the config
question above.

Full investigation, test transcripts, and the open follow-up are in
`.superpowers/sdd/kbd-task-6-report.md` (gitignored scratch, local only —
re-derive or re-run the tests in that report if it's gone). Before touching
Option/Alt key handling again, re-verify whether a newer libghostty pin
changes this API's behavior rather than assuming Casper's Swift-side wiring
is still the gap.
