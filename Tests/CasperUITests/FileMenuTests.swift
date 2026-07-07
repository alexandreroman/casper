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

    func testFileSubmenuDisablesAutoenabling() {
        // Regression test for the fix itself: `NSMenu.autoenablesItems` defaults to
        // true, which makes AppKit re-validate every item with a target that responds
        // to its action selector (true of every `ClosureMenuItem`) right before the
        // menu displays, silently overriding whatever `FileMenuDelegate.menuNeedsUpdate`
        // just set. Confirmed empirically: `NSMenu.update()`'s header doc states it
        // "triggers autovalidation" only when autoenablesItems is set, and does
        // "nothing" otherwise -- that autovalidation pass is what re-enabled the split
        // items after the delegate disabled them. `fileMenuItem()` must turn
        // autoenabling off so the delegate stays the only source of truth.
        let model = AppModel(sessionStore: makeStore())
        let item = model.fileMenuItem()

        XCTAssertFalse(item.submenu!.autoenablesItems)
    }

    func testRealSubmenuDisablesSplitItemsWhenNoSurfaceIsFocused() {
        // Unlike the two isolated tests above, this exercises the object graph
        // `fileMenuItem()` actually assembles -- the real submenu and the real
        // delegate it installs -- so a wiring mistake (wrong items passed to
        // `FileMenuDelegate`, or the delegate never attached to the submenu) would
        // also be caught, not just a `menuNeedsUpdate` logic bug.
        //
        // Note: this cannot go through `NSMenu.update()`, as AppKit only invokes
        // `menuNeedsUpdate` from its interactive menu-tracking path (there is no
        // `NSApplication` instance under `swift test`, and even force-creating
        // `NSApplication.shared` does not make `update()` call the delegate) --
        // confirmed empirically.
        let model = AppModel(sessionStore: makeStore())
        model.focusedSurfaceID = nil
        let item = model.fileMenuItem()
        let submenu = item.submenu!

        submenu.delegate?.menuNeedsUpdate?(submenu)

        let splitItems = submenu.items.filter { $0.title.hasPrefix("Split") }
        XCTAssertEqual(splitItems.count, 4)
        XCTAssertTrue(splitItems.allSatisfy { !$0.isEnabled })

        // `autoenablesItems = false` only means items keep whatever `isEnabled` they
        // were given (default true) unless something explicitly changes it. "Add
        // folder…" is never touched by `menuNeedsUpdate`, so it must stay enabled.
        let addFolderItem = submenu.items.first { $0.title == "Add folder…" }
        XCTAssertEqual(addFolderItem?.isEnabled, true)
    }

    func testRealSubmenuEnablesSplitItemsWhenASurfaceIsFocused() {
        let model = AppModel(sessionStore: makeStore())
        model.focusedSurfaceID = UUID()
        let item = model.fileMenuItem()
        let submenu = item.submenu!

        submenu.delegate?.menuNeedsUpdate?(submenu)

        let splitItems = submenu.items.filter { $0.title.hasPrefix("Split") }
        XCTAssertEqual(splitItems.count, 4)
        XCTAssertTrue(splitItems.allSatisfy(\.isEnabled))
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
