---
name: "NSEvent character accessors raise on non-key events"
description: "characters/charactersIgnoringModifiers raise NSInternalInconsistencyException outside keyDown/keyUp, and flagsChanged feeds exactly such events into the key-event builders"
type: reference
---

# NSEvent character accessors raise on non-key events

`-[NSEvent characters]` and `-[NSEvent charactersIgnoringModifiers]` are valid
on key events only. On any other event type they raise
`NSInternalInconsistencyException` ("Invalid message sent to event \"NSEvent:
type=FlagsChanged ... keyCode=59\""), an ObjC exception Swift cannot catch.
AppKit's event loop swallows it, so in the running app it surfaces as a logged
exception with no crash — while the throw still unwinds out of the whole call,
skipping everything after the read.

A modifier transition (Control, Shift, Option, Command, Caps Lock going down or
up) arrives as a `.flagsChanged` event through
`GhosttySurfaceView.flagsChanged(with:)`, which forwards it to
`ghosttyKeyEvent(_:action:)` in `Sources/CasperGhostty/GhosttyInput.swift`.
`ghosttyKeyEvent` reads `charactersIgnoringModifiers` once, only for `.keyDown`
/ `.keyUp`, and hands the result to both private helpers as `baseCharacters`
(`ghosttyUnshiftedCodepoint(from:)` and
`ghosttyControlComboKeycode(for:baseCharacters:)`), which never touch the
event's characters themselves. For any other event type it hands them `nil`,
and they fall back to `0` / the real keycode. Without that guard no modifier
press or release reaches libghostty at all, because the raise precedes
`sendKey`.

The resulting encoding for a modifier transition — `keycode = event.keyCode`,
`unshifted_codepoint = 0`, `text = nil` — matches what Ghostty's reference
`keyAction` sends ([[ghostty-is-the-reference]]).

**How to apply:** guard on the event type before reading characters off an
`NSEvent` in any path a non-key event can reach; `ghosttyTranslationEvent` is
safe only because `keyDown(with:)` is its sole caller. Synthesized
`.flagsChanged` events reproduce the raise faithfully:
`NSEvent.keyEvent(with: .flagsChanged, ...)` accepts the type and takes
character strings, and reading them back raises exactly as a real one does, so
this is directly testable in XCTest (`GhosttyInputTests`). Related:
[[ghostty-key-encoding]].
