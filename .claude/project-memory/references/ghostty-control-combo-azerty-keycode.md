---
name: "libghostty Control-letter encoding is physical-keycode-dependent"
description: "Bare Control-letter combos break on non-QWERTY layouts (AZERTY) unless the keycode is normalized to its QWERTY position"
type: reference
---

# libghostty Control-letter encoding is physical-keycode-dependent

The pinned libghostty binary encodes a bare (text-less) Control-letter combo — the
shell/readline shortcuts Ctrl-A/B/D/E/F/H/K/L/N/P/T/V/Y and friends — from the event's
*physical* `keycode` field, not purely from `unshifted_codepoint`. `keycode` reports
physical key **position** (e.g. macOS virtual keycode 0 is always the "A position" on
a US/ANSI layout, 12 is always the "Q position"), independent of what character the
user's active keyboard layout produces there. On AZERTY, the physical key that types
'a' sits at keycode 12 (the QWERTY 'Q' position), not keycode 0. Sending that combo's
real physical keycode straight through (as `ghosttyKeyEvent` used to do via
`UInt32(event.keyCode)`) makes libghostty mis-encode it: Ctrl-A wipes the whole line
instead of moving to its start, confirmed reproducible with `unshifted_codepoint`
correct (97, 'a') in both the working and broken case — only `keycode` differed
(0 vs 12). `ghostty_surface_key_is_binding` returns `false` for both, so this is not a
keybinding collision; it is libghostty's own bare-control-character encoding path.

**Fix landed**: `ghosttyControlComboKeycode(for:)` in
`Sources/CasperGhostty/GhosttyInput.swift` substitutes the letter's QWERTY-position
virtual keycode for any `.control` + ASCII-letter (a-z) combo, applied centrally in
`ghosttyKeyEvent(_:action:consumedMods:)`. `unshifted_codepoint` stays derived from the
real produced character; only `keycode` is normalized. Digits, punctuation, and
non-letter Control combos (Ctrl-[, Ctrl-Space, arrows, function keys) are left with
their real `event.keyCode` — no evidence they are affected and no safe remap target.

**Why this matters**: any future keyboard-input work must remember `keycode` is not
purely a "physical event descriptor" from libghostty's point of view for this specific
combo class — treat it as QWERTY-position-sensitive, not layout-agnostic, when a
Control modifier and a lettered `unshifted_codepoint` are both present.

**How to apply**: when touching bare-key (text-less) Control-combo encoding again,
keep going through `ghosttyControlComboKeycode`/`qwertyLetterKeyCodes` rather than
reverting to a raw `event.keyCode` pass-through. If extending remap coverage beyond
a-z (e.g. digits or punctuation under Control), verify on a real non-QWERTY layout
first — synthetic `NSEvent`s built with `keyCode: 0` will not reproduce this class of
bug; the real hardware keycode is what matters, and debug-channel `send-key` bypasses
`keyDown`/`interpretKeyEvents` entirely so it cannot exercise this path at all. See
[[ghostty-key-encoding]] for the sibling `unshifted_codepoint` control-encoding note,
and [[ghostty-is-the-reference]] — the vendored reference AppKit handler has the same
`input.keycode = UInt32(keyCode)` pattern, so it is not proof this class of bug is
absent upstream, only unverified there.
