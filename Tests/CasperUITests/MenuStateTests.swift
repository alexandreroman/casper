import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class MenuStateTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return SessionStore(fileURL: url)
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

    func testCloseAndDeleteEnabledForLinkedWorkspaceWithBaseBranch() {
        let model = makeModel(selecting: .linked, baseBranch: "main")
        XCTAssertTrue(model.canCloseSelectedWorkspace)
        XCTAssertTrue(model.canDeleteSelectedWorkspace)
    }

    func testCloseDisabledWhenLinkedWorkspaceHasNoBaseBranch() {
        let model = makeModel(selecting: .linked, baseBranch: nil)
        XCTAssertFalse(model.canCloseSelectedWorkspace)
        XCTAssertTrue(model.canDeleteSelectedWorkspace)
    }

    func testCloseAndDeleteDisabledForPrimaryWorkspace() {
        let model = makeModel(selecting: .primary)
        XCTAssertFalse(model.canCloseSelectedWorkspace)
        XCTAssertFalse(model.canDeleteSelectedWorkspace)
    }

    func testHasSelectedWorkspaceReflectsSelection() {
        let model = makeModel(selecting: .linked)
        XCTAssertTrue(model.hasSelectedWorkspace)
        model.selectedWorkspaceID = nil
        XCTAssertFalse(model.hasSelectedWorkspace)
    }

    func testCanSplitFocusedSurfaceReflectsFocus() {
        let model = AppModel(sessionStore: makeStore())
        model.focusedSurfaceID = nil
        XCTAssertFalse(model.canSplitFocusedSurface)
        model.focusedSurfaceID = UUID()
        XCTAssertTrue(model.canSplitFocusedSurface)
    }

    func testCanCreateWorkspaceIsFalseWithNoSpaces() {
        let model = AppModel(sessionStore: makeStore())
        XCTAssertFalse(model.canCreateWorkspace)
    }
}
