---
name: "libghostty Control-combo key encoding"
description: "Ctrl-combos need unshifted_codepoint on the key event; bare Control-letter combos also need the keycode normalized to its QWERTY position for non-QWERTY layouts"
type: reference
---

# libghostty Control-combo key encoding

Two coupled facts govern how a `ghostty_input_key_s` must be built for
Control combinations. Both live in `Sources/CasperGhostty/GhosttyInput.swift`
(`ghosttyKeyEvent(_:action:consumedMods:)`).

## `unshifted_codepoint` is mandatory

libghostty encodes control combinations (Ctrl-C → 0x03, Ctrl-D → 0x04) with the
xterm legacy algorithm on the key's **unshifted codepoint** (`'c'` & 0x1F = 0x03).
A `ghostty_input_key_s` for a Ctrl-combo therefore MUST set `unshifted_codepoint`
(from `event.charactersIgnoringModifiers`). Passing only `keycode` + `mods = CTRL`
with `unshifted_codepoint = 0` yields **no output** — the terminal silently
swallows Ctrl-C / Ctrl-D. So always populate `unshifted_codepoint` on every key
event built from an NSEvent, not just the text-carrying one.

macOS's `interpretKeyEvents` does not call `insertText` for Ctrl-combos (the
committed-text accumulator stays empty), so committed printable text and control
combos are distinct paths: control combos ride the bare key event and depend on
`unshifted_codepoint`; printable/IME text rides on `key.text`.

## `keycode` is QWERTY-position-sensitive for bare Control-letter combos

For a bare (text-less) Control-letter combo — the shell/readline shortcuts
Ctrl-A/B/D/E/F/H/K/L/N/P/T/V/Y and friends — libghostty encodes from the event's
*physical* `keycode` field, not purely from `unshifted_codepoint`. `keycode`
reports physical key **position** (macOS virtual keycode 0 is the US "A position",
12 the "Q position"), independent of the character the active layout produces.
On AZERTY the key that types 'a' sits at keycode 12 (the QWERTY 'Q' position), so
passing the raw physical keycode makes libghostty mis-encode it — Ctrl-A wipes the
whole line instead of moving to its start, with `unshifted_codepoint` correct
(97) in both the working and broken case. `ghostty_surface_key_is_binding` returns
`false`, so this is libghostty's own bare-control-character encoding path, not a
keybinding collision.

`ghosttyControlComboKeycode(for:)` (with `qwertyLetterKeyCodes`) substitutes the
letter's QWERTY-position virtual keycode for any `.control` + ASCII-letter (a-z)
combo; `unshifted_codepoint` stays derived from the real produced character. Digits,
punctuation, and non-letter Control combos (Ctrl-[, Ctrl-Space, arrows, function
keys) keep their real `event.keyCode` — no evidence they are affected and no safe
remap target.

**How to apply:** keep bare-Control-combo encoding going through
`ghosttyControlComboKeycode`/`qwertyLetterKeyCodes`, not a raw `event.keyCode`
pass-through. Verify Ctrl-combos end to end via the DEBUG `send-key <letter> --mods
ctrl` verb (e.g. Ctrl-C over a running `sleep`, confirm SIGINT). Synthetic
`NSEvent`s built with `keyCode: 0` do NOT reproduce the AZERTY class of bug (the
real hardware keycode is what matters), and the debug `send-key` channel bypasses
`keyDown`/`interpretKeyEvents` entirely, so it cannot exercise that path — the real
in-process harness in [[ghostty-real-surface-e2e-harness]] does. The vendored
reference AppKit handler ([[ghostty-is-the-reference]]) carries the same
`input.keycode = UInt32(keyCode)` pattern, so upstream is unverified, not proven
safe. See [[debug-channel-gating]] and [[ghostty-layer-contents-scale]] for other
libghostty embedding gotchas.
