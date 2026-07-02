---
name: "libghostty key event encoding"
description: "Ctrl-combos need unshifted_codepoint set on the key event; keycode+mods alone is not enough"
type: reference
---

# libghostty key event encoding

libghostty encodes control combinations (Ctrl-C → 0x03, Ctrl-D → 0x04) using the
xterm legacy algorithm on the key's **unshifted codepoint** (`'c'` & 0x1F = 0x03).
So a `ghostty_input_key_s` for a Ctrl-combo MUST set `unshifted_codepoint` (from
`event.charactersIgnoringModifiers`). Passing only `keycode` (the macOS virtual
keycode) + `mods = CTRL` with `unshifted_codepoint = 0` yields **no output** —
the terminal silently swallows Ctrl-C / Ctrl-D.

macOS's `interpretKeyEvents` does **not** call `insertText` for Ctrl-combos (the
committed-text accumulator stays empty), so committed printable text and control
combos are distinct paths: control combos ride the bare key event and depend on
`unshifted_codepoint`; printable/IME text rides on `key.text` (see the
cursor-position reason `key.text` is used instead of `ghostty_surface_text`).

Practical rule: always populate `unshifted_codepoint` on every key event built
from an NSEvent, not just the text-carrying one. Verify Ctrl-combos end to end
via the DEBUG `send-ctrl <letter>` debug-channel verb (companion to `send-keys`),
e.g. inject Ctrl-C over a running `sleep` and confirm SIGINT.

See [[debug-channel-gating]] and [[ghostty-layer-contents-scale]] for other
libghostty embedding gotchas.
