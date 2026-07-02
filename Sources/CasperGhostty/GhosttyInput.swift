import AppKit
import GhosttyKit

/// Map Cocoa modifier flags to libghostty's modifier bitset.
public func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(raw)
}

/// Build a libghostty key event from an NSEvent. Committed text is delivered
/// separately via `NSTextInputClient.insertText` → `GhosttySurface.sendText`, so
/// `text` is left null here.
public func ghosttyKeyEvent(
    _ event: NSEvent, action: ghostty_input_action_e
) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(from: event.modifierFlags)
    key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
    key.keycode = UInt32(event.keyCode)
    key.composing = false
    key.text = nil
    key.unshifted_codepoint = 0
    return key
}

/// macOS virtual keycode for Return (kVK_Return). Used to synthesize a
/// line-submission key event when no NSEvent is available (debug channel).
public let ghosttyReturnKeyCode: UInt32 = 36

/// Build a libghostty key event not backed by an NSEvent (e.g. debug-channel
/// injection). `mods` defaults to none.
public func ghosttyKeyEvent(
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
