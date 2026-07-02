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
}
