import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

final class GhosttyInputTests: XCTestCase {
    func testNoModifiersIsEmpty() {
        XCTAssertEqual(ghosttyMods(from: []).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testCommandShiftMapsToSuperShift() {
        let mods = ghosttyMods(from: [.command, .shift])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }

    func testControlOptionMapsToCtrlAlt() {
        let mods = ghosttyMods(from: [.control, .option])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
    }

    func testControlCharactersDoNotRideOnKeyEvent() {
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\u{03}"))  // Ctrl-C
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\u{04}"))  // Ctrl-D
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\r"))  // 0x0D
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\t"))  // 0x09
    }

    func testPrintableTextRidesOnKeyEvent() {
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent("a"))
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent(" "))  // space, 0x20
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent("é"))
    }

    func testEmptyTextDoesNotRideOnKeyEvent() {
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent(""))
    }

    /// Guards the fix where the bare key event left `unshifted_codepoint` at 0, which silently
    /// disabled libghostty's control encoding so Ctrl-C/Ctrl-D produced no output.
    func testBareKeyEventCarriesUnshiftedCodepointForControlEncoding() {
        let event = makeControlCKeyEvent()
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.unshifted_codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertNil(key.text)
    }
}

/// Build a synthetic Ctrl-C keyDown. A real Control press remaps `characters` to the control
/// scalar (U+0003) while `charactersIgnoringModifiers` stays the base key ("c"), which is what
/// `unshifted_codepoint` must be derived from.
private func makeControlCKeyEvent() -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{03}",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8  // kVK_ANSI_C
    )!
}
