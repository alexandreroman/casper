import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// Covers `ghosttyTranslationEvent`, the pure helper that decides whether Option
/// should reach Cocoa's text composition system (macOS default: compose an
/// accented/special character) or be stripped so it reaches the terminal as a bare
/// Alt/Meta modifier (`macos-option-as-alt = true`, resolved upstream by libghostty's
/// `ghostty_surface_key_translation_mods` into the `translationMods` parameter here).
final class GhosttyOptionAsAltTests: XCTestCase {
    private func makeKeyEvent(
        keyCode: UInt16 = 11,  // kVK_ANSI_B
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // `macos-option-as-alt = true`: libghostty's translation mods omit Alt, so Option
    // must not reach Cocoa's composition — otherwise Meta-b never reaches the shell.
    func testOptionStrippedWhenLibghosttySaysNotToCompose() {
        let event = makeKeyEvent(modifierFlags: [.option])
        let translated = ghosttyTranslationEvent(
            for: event, translationMods: ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue))
        XCTAssertFalse(translated.modifierFlags.contains(.option))
    }

    // Default macOS behavior (`macos-option-as-alt = false`): libghostty's translation
    // mods include Alt, so Option must still reach Cocoa to compose special characters.
    func testOptionKeptWhenLibghosttySaysToCompose() {
        let event = makeKeyEvent(modifierFlags: [.option])
        let translated = ghosttyTranslationEvent(
            for: event, translationMods: ghostty_input_mods_e(GHOSTTY_MODS_ALT.rawValue))
        XCTAssertTrue(translated === event)
        XCTAssertTrue(translated.modifierFlags.contains(.option))
    }

    // No Option held: nothing to translate, regardless of libghostty's answer.
    func testNonOptionEventIsUnaffected() {
        let event = makeKeyEvent(modifierFlags: [.shift])
        let translated = ghosttyTranslationEvent(
            for: event, translationMods: ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue))
        XCTAssertTrue(translated === event)
    }

    // Stripping Option must not disturb other modifiers riding on the same event.
    func testOtherModifiersSurviveOptionStripping() {
        let event = makeKeyEvent(modifierFlags: [.option, .shift])
        let translated = ghosttyTranslationEvent(
            for: event, translationMods: ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue))
        XCTAssertFalse(translated.modifierFlags.contains(.option))
        XCTAssertTrue(translated.modifierFlags.contains(.shift))
    }

    // `ghosttyKeyEvent`'s `consumedMods` parameter must plumb straight through to
    // `consumed_mods` on the built key, and default to NONE when the caller omits it —
    // this is what lets `keyDown` send bare (text-less) events, like Option+arrows,
    // without telling libghostty Alt was consumed and losing their Meta encoding.
    func testConsumedModsPlumbsThroughAndDefaultsToNone() {
        let event = makeKeyEvent(modifierFlags: [.option])

        let withAlt = ghosttyKeyEvent(
            event, action: GHOSTTY_ACTION_PRESS,
            consumedMods: ghostty_input_mods_e(GHOSTTY_MODS_ALT.rawValue))
        XCTAssertEqual(withAlt.consumed_mods.rawValue, GHOSTTY_MODS_ALT.rawValue)

        let withDefault = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(withDefault.consumed_mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
    }
}
