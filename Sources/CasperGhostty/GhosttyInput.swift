import AppKit
import GhosttyKit

/// Map Cocoa modifier flags to libghostty's modifier bitset.
func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(raw)
}

/// Build a libghostty key event from an NSEvent with no text payload. Used for
/// keystrokes that commit no text (arrows, Return, Backspace, Ctrl-combos), where
/// the keycode drives libghostty's own encoding. It populates `unshifted_codepoint`
/// (required so libghostty can encode control characters such as Ctrl-C → U+0003
/// from the base key) and only leaves `text` nil. Committed typed text instead
/// rides on the key event via the `text`-carrying overload below.
///
/// `consumedMods` tells libghostty which modifiers Cocoa's text system already
/// spent while composing the event (e.g. Option composing an accented character),
/// so it does not also re-encode them as an escape sequence. Defaults to none.
func ghosttyKeyEvent(
    _ event: NSEvent, action: ghostty_input_action_e,
    consumedMods: ghostty_input_mods_e = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(from: event.modifierFlags)
    key.consumed_mods = consumedMods
    // For a Control-letter combo, send the letter's QWERTY-position keycode rather than
    // the real physical keycode (see `ghosttyControlComboKeycode`); every other key
    // keeps its real `event.keyCode`.
    key.keycode = ghosttyControlComboKeycode(for: event) ?? UInt32(event.keyCode)
    key.composing = false
    key.text = nil
    key.unshifted_codepoint = ghosttyUnshiftedCodepoint(from: event)
    return key
}

/// Build a libghostty key event from an NSEvent carrying committed text on the
/// press. libghostty expects typed text attached to the key event (`key.text`),
/// not delivered through the separate `ghostty_surface_text` path — that path is
/// for pasted/IME bulk text and leaves the block cursor rendering on the last
/// character instead of the empty cell after it.
///
/// `text` must stay valid for the duration of the `ghostty_surface_key` call, so
/// callers pass a pointer obtained from `String.withCString` and invoke `sendKey`
/// inside that closure, never returning an event whose `text` has been freed.
///
/// The bare overload this delegates to already sets `unshifted_codepoint`; this
/// overload only attaches the committed `text`.
func ghosttyKeyEvent(
    _ event: NSEvent, action: ghostty_input_action_e, text: UnsafePointer<CChar>?,
    consumedMods: ghostty_input_mods_e = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
) -> ghostty_input_key_s {
    var key = ghosttyKeyEvent(event, action: action, consumedMods: consumedMods)
    key.text = text
    return key
}

/// Build the event AppKit's text composition system (`interpretKeyEvents`) should
/// see, honoring libghostty's resolved `macos-option-as-alt` config. `translationMods`
/// is libghostty's answer (via `ghostty_surface_key_translation_mods`) to "which
/// modifiers should drive text composition for this event" — Casper never reads the
/// config value itself, only this resolved answer.
///
/// macOS's default is Option composing accented/special characters (e.g. Option-e
/// then e → é). When `macos-option-as-alt = true`, Option must instead reach the
/// terminal as a bare Alt/Meta modifier (e.g. Meta-b → backward-word in bash), which
/// requires Cocoa not to consume Option for composition at all — so this strips
/// `.option` from the event before Cocoa sees it whenever libghostty's answer omits
/// the Alt bit. Mirrors Ghostty's own AppKit key handling.
func ghosttyTranslationEvent(
    for event: NSEvent, translationMods: ghostty_input_mods_e
) -> NSEvent {
    let optionDrivesComposition = translationMods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0
    guard event.modifierFlags.contains(.option), !optionDrivesComposition else { return event }

    let strippedFlags = event.modifierFlags.subtracting(.option)
    return NSEvent.keyEvent(
        with: event.type,
        location: event.locationInWindow,
        modifierFlags: strippedFlags,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: event.characters(byApplyingModifiers: strippedFlags) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
    ) ?? event
}

/// Whether committed text should ride on the key event's `text` field. libghostty
/// encodes control characters itself from the keycode + modifiers, so a bare
/// control character (Ctrl-C → U+0003, Ctrl-D → U+0004) must NOT be attached as
/// `key.text` or libghostty mis-encodes it and the Ctrl combination is lost. Only
/// text whose first UTF-8 byte is printable (>= 0x20) rides on the key event.
/// Mirrors Ghostty's keyAction guard.
func ghosttyTextRidesOnKeyEvent(_ text: String) -> Bool {
    guard let first = text.utf8.first else { return false }
    return first >= 0x20
}

/// Codepoint of the base key with modifiers ignored, which libghostty uses to
/// resolve keybindings against the physical key. Zero when the event exposes no
/// such scalar.
private func ghosttyUnshiftedCodepoint(from event: NSEvent) -> UInt32 {
    guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return 0 }
    return scalar.value
}

/// For a Control + ASCII-letter combo, the QWERTY-position virtual keycode to send in
/// place of the event's real physical keycode; nil for every other event, which then
/// keeps its real `event.keyCode`.
///
/// libghostty encodes a bare (text-less) Control-letter combo from the *physical*
/// keycode, and the pinned binary mis-encodes combos struck on non-QWERTY positions:
/// on an AZERTY keyboard 'a' sits at the QWERTY 'Q' position (keycode 12), and Ctrl-A
/// there wipes the line instead of moving to its start. Substituting the letter's
/// QWERTY keycode makes the intended control character encode correctly regardless of
/// the user's physical layout. Only `keycode` is normalized — `unshifted_codepoint`
/// still carries the real produced letter. Scoped to Control combos on mapped letters
/// (a–z); digits, punctuation, and combos like Ctrl-[ or Ctrl-Space keep their real
/// keycode, since there is no evidence they are affected and no safe remap target.
private func ghosttyControlComboKeycode(for event: NSEvent) -> UInt32? {
    guard event.modifierFlags.contains(.control),
        let base = event.charactersIgnoringModifiers?.lowercased().first,
        let keycode = qwertyLetterKeyCodes[base]
    else { return nil }
    return keycode
}

/// macOS ANSI virtual keycodes (`kVK_ANSI_*`) named rather than inlined so the maps
/// below read as key names, not magic numbers. Values match Carbon's HIToolbox
/// constants.
private enum VirtualKeyCode {
    static let a: UInt32 = 0
    static let s: UInt32 = 1
    static let d: UInt32 = 2
    static let f: UInt32 = 3
    static let h: UInt32 = 4
    static let g: UInt32 = 5
    static let z: UInt32 = 6
    static let x: UInt32 = 7
    static let c: UInt32 = 8
    static let v: UInt32 = 9
    static let b: UInt32 = 11
    static let q: UInt32 = 12
    static let w: UInt32 = 13
    static let e: UInt32 = 14
    static let r: UInt32 = 15
    static let y: UInt32 = 16
    static let t: UInt32 = 17
    static let o: UInt32 = 31
    static let u: UInt32 = 32
    static let i: UInt32 = 34
    static let p: UInt32 = 35
    static let l: UInt32 = 37
    static let j: UInt32 = 38
    static let k: UInt32 = 40
    static let n: UInt32 = 45
    static let m: UInt32 = 46
    // Digits and space are referenced only by the debug-only `send-keys` key table
    // (`unshiftedKeyCodes`), so they compile in DEBUG builds alone.
    #if DEBUG
    static let one: UInt32 = 18
    static let two: UInt32 = 19
    static let three: UInt32 = 20
    static let four: UInt32 = 21
    static let five: UInt32 = 23
    static let six: UInt32 = 22
    static let seven: UInt32 = 26
    static let eight: UInt32 = 28
    static let nine: UInt32 = 25
    static let zero: UInt32 = 29
    static let space: UInt32 = 49
    #endif
}

/// QWERTY-position virtual keycode for each ASCII letter, used to normalize
/// Control-letter combos (see `ghosttyControlComboKeycode`).
private let qwertyLetterKeyCodes: [Character: UInt32] = [
    "a": VirtualKeyCode.a, "b": VirtualKeyCode.b, "c": VirtualKeyCode.c,
    "d": VirtualKeyCode.d, "e": VirtualKeyCode.e, "f": VirtualKeyCode.f,
    "g": VirtualKeyCode.g, "h": VirtualKeyCode.h, "i": VirtualKeyCode.i,
    "j": VirtualKeyCode.j, "k": VirtualKeyCode.k, "l": VirtualKeyCode.l,
    "m": VirtualKeyCode.m, "n": VirtualKeyCode.n, "o": VirtualKeyCode.o,
    "p": VirtualKeyCode.p, "q": VirtualKeyCode.q, "r": VirtualKeyCode.r,
    "s": VirtualKeyCode.s, "t": VirtualKeyCode.t, "u": VirtualKeyCode.u,
    "v": VirtualKeyCode.v, "w": VirtualKeyCode.w, "x": VirtualKeyCode.x,
    "y": VirtualKeyCode.y, "z": VirtualKeyCode.z,
]

#if DEBUG
/// macOS virtual keycode for Return (kVK_Return). Used to synthesize a
/// line-submission key event when no NSEvent is available (debug channel).
let ghosttyReturnKeyCode: UInt32 = 36

/// Build a libghostty key event not backed by an NSEvent (e.g. debug-channel
/// injection). `mods` defaults to none.
func ghosttyKeyEvent(
    keycode: UInt32,
    action: ghostty_input_action_e,
    mods: ghostty_input_mods_e = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = mods
    key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
    key.keycode = keycode
    key.composing = false
    key.text = nil
    key.unshifted_codepoint = 0
    return key
}

/// Build a libghostty key event carrying a character payload, for debug-channel
/// injection that must look like genuine keyboard typing (`send-keys`). Unlike the
/// text/paste path, this populates `text` (the committed character, press only)
/// and `unshifted_codepoint` (the base key's codepoint) so libghostty emits the
/// character through its key path.
///
/// `text` must stay valid for the duration of the `ghostty_surface_key` call, so
/// callers pass a pointer obtained from `String.withCString` and invoke `sendKey`
/// inside that closure. Release events pass `text = nil`, mirroring real key-up.
func ghosttyKeyEvent(
    keycode: UInt32,
    action: ghostty_input_action_e,
    mods: ghostty_input_mods_e,
    text: UnsafePointer<CChar>?,
    unshiftedCodepoint: UInt32
) -> ghostty_input_key_s {
    var key = ghosttyKeyEvent(keycode: keycode, action: action, mods: mods)
    key.text = text
    key.unshifted_codepoint = unshiftedCodepoint
    return key
}

/// Map debug-channel modifier names ("ctrl", "cmd"/"super", "opt"/"alt", "shift")
/// to libghostty's modifier bitset. Unknown names are ignored. Debug-only helper
/// for `send-key`.
func ghosttyModsFromNames(_ names: [String]) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    for name in names {
        switch name.lowercased() {
        case "ctrl", "control": raw |= GHOSTTY_MODS_CTRL.rawValue
        case "cmd", "command", "super": raw |= GHOSTTY_MODS_SUPER.rawValue
        case "opt", "option", "alt": raw |= GHOSTTY_MODS_ALT.rawValue
        case "shift": raw |= GHOSTTY_MODS_SHIFT.rawValue
        default: break
        }
    }
    return ghostty_input_mods_e(raw)
}

/// A physical key resolved from a `Character` for debug key injection: the macOS
/// virtual keycode of the base (unshifted) key, that key's Unicode codepoint, and
/// whether Shift is required (uppercase letters). Real macOS typing of 'H' reports
/// the 'h' physical key plus Shift, so injection must do the same.
struct GhosttyInjectedKey: Equatable, Sendable {
    let keycode: UInt32
    let unshiftedCodepoint: UInt32
    let needsShift: Bool
}

/// Virtual keycode for each supported *unshifted* character: the shared letter table
/// plus the digits and space the debug `send-keys` verb can synthesize. Uppercase
/// letters are not listed: they resolve to their lowercase entry plus Shift (see the
/// resolver).
private let unshiftedKeyCodes: [Character: UInt32] = qwertyLetterKeyCodes.merging([
    "0": VirtualKeyCode.zero, "1": VirtualKeyCode.one, "2": VirtualKeyCode.two,
    "3": VirtualKeyCode.three, "4": VirtualKeyCode.four, "5": VirtualKeyCode.five,
    "6": VirtualKeyCode.six, "7": VirtualKeyCode.seven, "8": VirtualKeyCode.eight,
    "9": VirtualKeyCode.nine,
    " ": VirtualKeyCode.space,
]) { current, _ in current }

/// Resolve a `Character` to the physical key a real keyboard would press to type
/// it, or nil when the character is outside the supported set (letters, digits,
/// space). Uppercase letters map to the lowercase key plus Shift.
func ghosttyInjectedKey(for character: Character) -> GhosttyInjectedKey? {
    let needsShift = character.isUppercase
    let base: Character = needsShift ? Character(character.lowercased()) : character
    guard let keycode = unshiftedKeyCodes[base] else { return nil }
    // The base key is a single ASCII scalar for every mapped entry.
    guard base.unicodeScalars.count == 1, let scalar = base.unicodeScalars.first else { return nil }
    return GhosttyInjectedKey(keycode: keycode, unshiftedCodepoint: scalar.value, needsShift: needsShift)
}
#endif
