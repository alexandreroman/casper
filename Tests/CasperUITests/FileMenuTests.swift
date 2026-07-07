import AppKit
import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class FileMenuTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return SessionStore(fileURL: url)
    }

    private func makeItems() -> [NSMenuItem] {
        (0..<4).map { NSMenuItem(title: "item-\($0)", action: nil, keyEquivalent: "") }
    }

    func testDisablesSplitItemsWhenNoSurfaceIsFocused() {
        let model = AppModel(sessionStore: makeStore())
        model.focusedSurfaceID = nil
        let items = makeItems()
        let delegate = FileMenuDelegate(model: model, splitItems: items)

        delegate.menuNeedsUpdate(NSMenu())

        XCTAssertTrue(items.allSatisfy { !$0.isEnabled })
    }

    func testEnablesSplitItemsWhenASurfaceIsFocused() {
        let model = AppModel(sessionStore: makeStore())
        model.focusedSurfaceID = UUID()
        let items = makeItems()
        let delegate = FileMenuDelegate(model: model, splitItems: items)

        delegate.menuNeedsUpdate(NSMenu())

        XCTAssertTrue(items.allSatisfy(\.isEnabled))
    }

    func testFileMenuItemBuildsExpectedTitlesInOrder() {
        let model = AppModel(sessionStore: makeStore())
        let item = model.fileMenuItem()
        let titles = item.submenu?.items.map(\.title)
        XCTAssertEqual(titles, [
            "Add folder…", NSMenuItem.separator().title,
            "Split up", "Split down", "Split left", "Split right",
        ])
    }
}
