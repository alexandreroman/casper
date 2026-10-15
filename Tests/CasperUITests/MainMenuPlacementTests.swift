import AppKit
import Foundation
import XCTest
@testable import CasperUI

/// `AppDelegate`'s main-menu fixups — the empty-stub strip, the File → Space rename and
/// the Workspace move — over a hand-built main menu shaped like the one SwiftUI
/// produces: the Workspace `CommandMenu` between View and Window, and the File slot
/// recognizable by its first item, New Space….
@MainActor
final class MainMenuPlacementTests: XCTestCase {
    /// A top-level item whose submenu holds `firstItem`, or nothing at all when it is
    /// nil — an emptied stub, or a `CommandMenu` SwiftUI has not filled yet.
    private func topLevelItem(_ title: String, firstItem: String? = "Item") -> NSMenuItem {
        let submenu = NSMenu(title: title)
        if let firstItem { submenu.addItem(withTitle: firstItem, action: nil, keyEquivalent: "") }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The bar as SwiftUI lays it out, the File slot already retitled or not.
    private func makeSwiftUIMainMenu(fileTitle: String = "File") -> NSMenu {
        let mainMenu = NSMenu(title: "Main")
        mainMenu.addItem(topLevelItem("Casper"))
        mainMenu.addItem(topLevelItem(fileTitle, firstItem: CasperCommands.newSpaceTitle))
        mainMenu.addItem(topLevelItem("Edit"))
        mainMenu.addItem(topLevelItem("View"))
        mainMenu.addItem(topLevelItem(CasperCommands.workspaceMenuTitle, firstItem: "New Workspace…"))
        mainMenu.addItem(topLevelItem("Window"))
        return mainMenu
    }

    /// The bar as a SwiftUI re-assert hands it over: the emptied Format and Help stubs
    /// back in place, and the Workspace submenu not filled yet.
    private func makeReassertedMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main")
        mainMenu.addItem(topLevelItem("Casper"))
        mainMenu.addItem(topLevelItem("File", firstItem: CasperCommands.newSpaceTitle))
        mainMenu.addItem(topLevelItem("Edit"))
        mainMenu.addItem(topLevelItem("Format", firstItem: nil))
        mainMenu.addItem(topLevelItem("View"))
        mainMenu.addItem(topLevelItem(CasperCommands.workspaceMenuTitle, firstItem: nil))
        mainMenu.addItem(topLevelItem("Window"))
        mainMenu.addItem(topLevelItem("Help", firstItem: nil))
        return mainMenu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        (0..<menu.numberOfItems).compactMap { menu.item(at: $0)?.title }
    }

    func testWorkspaceMovesRightAfterTheSpaceMenu() {
        let mainMenu = makeSwiftUIMainMenu()
        let workspaceItem = mainMenu.item(withTitle: CasperCommands.workspaceMenuTitle)

        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: mainMenu)

        XCTAssertEqual(titles(mainMenu), ["Casper", "File", "Workspace", "Edit", "View", "Window"])
        XCTAssertTrue(
            mainMenu.item(at: 2) === workspaceItem,
            "the very item SwiftUI built moves, submenu and all — never a copy")
        XCTAssertEqual(mainMenu.item(at: 2)?.submenu?.item(at: 0)?.title, "New Workspace…")
    }

    /// The Space menu is found by its first item, so the retitle does not matter.
    func testWorkspaceFollowsTheRetitledSpaceMenu() {
        let mainMenu = makeSwiftUIMainMenu(fileTitle: "Space")
        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: mainMenu)
        XCTAssertEqual(titles(mainMenu), ["Casper", "Space", "Workspace", "Edit", "View", "Window"])
    }

    /// The pass runs after nearly every event, so a bar already in order must not be
    /// touched at all — a remove-and-reinsert would churn the menu for nothing.
    func testABarAlreadyInOrderIsLeftUntouched() {
        let mainMenu = makeSwiftUIMainMenu()
        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: mainMenu)

        var mutations = 0
        let center = NotificationCenter.default
        let observers = [NSMenu.didRemoveItemNotification, NSMenu.didAddItemNotification].map { name in
            center.addObserver(forName: name, object: mainMenu, queue: nil) { _ in
                MainActor.assumeIsolated { mutations += 1 }
            }
        }
        defer { observers.forEach(center.removeObserver) }

        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: mainMenu)

        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(titles(mainMenu), ["Casper", "File", "Workspace", "Edit", "View", "Window"])
    }

    /// Mid-resync, SwiftUI's bar can lack either menu, or carry empty stubs that have
    /// not been stripped yet; none of that may move anything or trap.
    func testAnIncompleteBarIsLeftAlone() {
        let noWorkspace = makeSwiftUIMainMenu()
        noWorkspace.removeItem(at: 4)
        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: noWorkspace)
        XCTAssertEqual(titles(noWorkspace), ["Casper", "File", "Edit", "View", "Window"])

        let noSpace = makeSwiftUIMainMenu()
        noSpace.removeItem(at: 1)
        let emptyStub = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        emptyStub.submenu = NSMenu(title: "Help")
        noSpace.addItem(emptyStub)
        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: noSpace)
        XCTAssertEqual(titles(noSpace), ["Casper", "Edit", "View", "Workspace", "Window", "Help"])
    }

    /// The strip removes SwiftUI's emptied Format/Help stubs but never the Workspace
    /// menu, whose submenu SwiftUI fills only when it is opened: stripped while empty,
    /// it would never come back.
    func testTheStripRemovesEmptyStubsButKeepsTheUnfilledWorkspaceMenu() {
        let mainMenu = makeReassertedMainMenu()
        AppDelegate.stripEmptyTopLevelMenus(in: mainMenu)
        XCTAssertEqual(titles(mainMenu), ["Casper", "File", "Edit", "View", "Workspace", "Window"])
    }

    /// The whole resync, in `resyncMainMenu()`'s order, over a re-asserted bar: the
    /// Workspace menu survives its empty submenu, is found by title, and lands right
    /// after the retitled Space menu.
    func testAFullResyncPassOverAReassertedBar() {
        let mainMenu = makeReassertedMainMenu()
        let workspaceItem = mainMenu.item(withTitle: CasperCommands.workspaceMenuTitle)

        AppDelegate.stripEmptyTopLevelMenus(in: mainMenu)
        AppDelegate.renameFileMenu(in: mainMenu)
        AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in: mainMenu)

        XCTAssertEqual(titles(mainMenu), ["Casper", "Space", "Workspace", "Edit", "View", "Window"])
        XCTAssertTrue(mainMenu.item(at: 2) === workspaceItem)
        XCTAssertEqual(mainMenu.item(at: 1)?.submenu?.title, AppDelegate.spaceMenuTitle)
    }
}
