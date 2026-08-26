#if DEBUG
import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

final class GhosttyInputModsTests: XCTestCase {
    func testParsesCtrlAndSuper() {
        let mods = ghosttyModsFromNames(["ctrl", "cmd"])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
    }

    func testUnknownNameIsIgnored() {
        let mods = ghosttyModsFromNames(["bogus"])
        XCTAssertEqual(mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testParsesOptAndAlt() {
        for name in ["opt", "alt"] {
            let mods = ghosttyModsFromNames([name])
            XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        }
    }

    func testParsesShift() {
        let mods = ghosttyModsFromNames(["shift"])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0)
    }

    // Caps Lock is a modifier in its own right: `flagsChanged` sends a press for
    // keyCode 0x39, and a keystroke typed with it on must carry the bit too.
    func testMapsCapsLockFromEventFlags() {
        let mods = ghosttyMods(from: [.capsLock])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CAPS.rawValue, 0)
    }

    // Guards against a regression where a case-sensitive check downstream of
    // `ghosttyModsFromNames` disagreed with this function's own lowercasing.
    func testParsingIsCaseInsensitive() {
        let mods = ghosttyModsFromNames(["CTRL"])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }
}
#endif
