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

    func testFileSubmenuDisablesAutoenabling() {
        // Regression test for the fix itself: `NSMenu.autoenablesItems` defaults to
        // true, which makes AppKit re-validate every item with a target that responds
        // to its action selector (true of every `ClosureMenuItem`) right before the
        // menu displays, silently overriding whatever `FileMenuDelegate.menuNeedsUpdate`
        // just set. Confirmed empirically: `NSMenu.update()`'s header doc states it
        // "triggers autovalidation" only when autoenablesItems is set, and does
        // "nothing" otherwise -- that autovalidation pass is what re-enabled the merge/
        // delete items after the delegate disabled them. `fileMenuItem()` must turn
        // autoenabling off so the delegate stays the only source of truth.
        let model = AppModel(sessionStore: makeStore())
        let item = model.fileMenuItem()

        XCTAssertFalse(item.submenu!.autoenablesItems)
    }

    private func makeModel(selecting kind: WorkspaceKind, baseBranch: String? = "main") -> AppModel {
        let primary = Workspace(
            name: "main", worktreePath: "/tmp/primary", branch: "main",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: "/tmp/primary")))
        let linked = Workspace(
            name: "feature", worktreePath: "/tmp/feature", branch: "feature",
            portBase: 42010, layout: .leaf(Surface.terminal(cwd: "/tmp/feature")),
            kind: .linked, baseBranch: baseBranch)
        let space = Space(name: "main", folderPath: "/tmp", isGitRepo: true, workspaces: [primary, linked])
        let selectedID = kind == .primary ? primary.id : linked.id
        let session = Session(spaces: [space], selectedWorkspaceID: selectedID)
        return AppModel(sessionStore: makeStore(), session: session)
    }

    func testEnablesCloseAndDeleteWhenLinkedWorkspaceWithBaseBranchIsSelected() {
        let model = makeModel(selecting: .linked, baseBranch: "main")
        let item = model.fileMenuItem()
        let submenu = item.submenu!
        submenu.delegate?.menuNeedsUpdate?(submenu)

        let closeItem = submenu.items.first { $0.title == "Merge and Close Workspace…" }
        let deleteItem = submenu.items.first { $0.title == "Delete Workspace…" }
        XCTAssertEqual(closeItem?.isEnabled, true)
        XCTAssertEqual(deleteItem?.isEnabled, true)
    }

    func testDisablesCloseWhenSelectedLinkedWorkspaceHasNoBaseBranch() {
        let model = makeModel(selecting: .linked, baseBranch: nil)
        let item = model.fileMenuItem()
        let submenu = item.submenu!
        submenu.delegate?.menuNeedsUpdate?(submenu)

        let closeItem = submenu.items.first { $0.title == "Merge and Close Workspace…" }
        let deleteItem = submenu.items.first { $0.title == "Delete Workspace…" }
        XCTAssertEqual(closeItem?.isEnabled, false)
        XCTAssertEqual(deleteItem?.isEnabled, true)
    }

    func testDisablesCloseAndDeleteWhenPrimaryWorkspaceIsSelected() {
        let model = makeModel(selecting: .primary)
        let item = model.fileMenuItem()
        let submenu = item.submenu!
        submenu.delegate?.menuNeedsUpdate?(submenu)

        let closeItem = submenu.items.first { $0.title == "Merge and Close Workspace…" }
        let deleteItem = submenu.items.first { $0.title == "Delete Workspace…" }
        XCTAssertEqual(closeItem?.isEnabled, false)
        XCTAssertEqual(deleteItem?.isEnabled, false)
    }

    func testAddFolderItemHasCommandOShortcut() {
        let model = AppModel(sessionStore: makeStore())
        let submenu = model.fileMenuItem().submenu!
        let addItem = submenu.items.first { $0.title == "Add Folder…" }
        XCTAssertEqual(addItem?.keyEquivalent, "o")
        XCTAssertEqual(addItem?.keyEquivalentModifierMask, .command)
    }

    func testFileMenuItemBuildsExpectedTitlesInOrder() {
        let model = AppModel(sessionStore: makeStore())
        let item = model.fileMenuItem()
        let titles = item.submenu?.items.map(\.title)
        XCTAssertEqual(titles, [
            "Add Folder…", NSMenuItem.separator().title,
            "Merge and Close Workspace…", "Delete Workspace…",
        ])
    }
}
