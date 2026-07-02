#if DEBUG
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
}
#endif
