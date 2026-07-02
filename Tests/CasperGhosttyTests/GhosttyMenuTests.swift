import AppKit
import XCTest
@testable import CasperGhostty

@MainActor
final class GhosttyMenuTests: XCTestCase {
    func testMenuHasEditViewWindow() {
        let menu = buildMainMenu()
        let titles = menu.items.compactMap { $0.submenu?.title }
        XCTAssertTrue(titles.contains("Edit"))
        XCTAssertTrue(titles.contains("View"))
        XCTAssertTrue(titles.contains("Window"))
    }

    func testEditMenuHasCopyPasteSelectAll() {
        let menu = buildMainMenu()
        let edit = menu.items.first { $0.submenu?.title == "Edit" }?.submenu
        let keys = edit?.items.map { $0.keyEquivalent } ?? []
        XCTAssertTrue(keys.contains("c"))
        XCTAssertTrue(keys.contains("v"))
        XCTAssertTrue(keys.contains("a"))
    }
}
