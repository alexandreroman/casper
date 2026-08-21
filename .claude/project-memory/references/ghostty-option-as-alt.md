---
name: "Ghostty option-as-alt"
description: "macos-option-as-alt wiring, and the pinned libghostty binary's unconfirmed behavior for it"
type: reference
---

# Ghostty option-as-alt

`GhosttySurfaceView.keyDown` calls
`ghostty_surface_key_translation_mods(surface,
rawMods)` before `interpretKeyEvents`, and strips `.option` from the event Cocoa
sees (via `ghosttyTranslationEvent` in `GhosttyInput.swift`) whenever
libghostty's answer omits the Alt bit. This is the mechanism real Ghostty's
macOS app uses for `macos-option-as-alt`, and matches the reference AppKit key
handler vendored under
`.build/checkouts/libghostty-spm/.../TerminalKeyEventHandler@AppKit.swift` (read
for reference only, not a Casper dependency).

**Unconfirmed in the pinned binary:** end-to-end `NSEvent`-driven Option
keypresses (via AppleScript `System Events`, which exercises the true
`keyDown`/`interpretKeyEvents` path — the debug `send-key` channel does not,
since it calls `ghostty_surface_key` directly) show
`ghostty_surface_key_translation_mods` returning the Alt bit unchanged for a
plain Option+letter combo, identically under the default config and a scratch
config with `macos-option-as-alt = true`. Option composes a special character in
both cases; the config's effect on this API's answer is not observable for the
pinned libghostty binary (Lakr233/libghostty-spm 1.2.8 = Ghostty v1.3.1).

Independently: when a key event sent to `ghostty_surface_key` carries non-nil
`text`, libghostty inserts it verbatim regardless of `mods`/`consumed_mods` —
the ESC-prefixed Meta-encoding path runs only for text-less key events. This is
why the debug `send-key --mods opt` path can never demonstrate Meta-b (it always
attaches `text`), independent of the config question above.

Full investigation and test transcripts live in
`.superpowers/sdd/kbd-task-6-report.md` (gitignored scratch, local only — re-run
the tests if it is gone). Before touching Option/Alt key handling, re-verify
whether a newer libghostty pin changes this API's behavior rather than assuming
Casper's Swift-side wiring is the gap.
