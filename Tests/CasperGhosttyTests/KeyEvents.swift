import AppKit

/// A synthetic key event shaped the way a real keyboard reports it, for the tests that
/// drive a surface view's key handling. `characters` is what the key produced (the control
/// scalar for a Control combo); `ignoringModifiers` is the base key, `characters` when
/// omitted. Force-unwrapped: every caller passes literals of a key event type, for which
/// `NSEvent.keyEvent` does not return nil.
func keyEvent(
    _ characters: String, ignoringModifiers: String? = nil, modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16, type: NSEvent.EventType = .keyDown
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false, keyCode: keyCode)!
}
