import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class AppModelTests: XCTestCase {
    private func makeStore() -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return (SessionStore(fileURL: url), url)
    }

    func testStartsEmptyWhenSessionEmpty() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.selectedWorkspaceID)
    }

    func testAddWorkspaceAppendsSelectsAndPersists() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/plain"), probe: { _ in nil })
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.workspaces[0].id)
        // Persisted synchronously.
        XCTAssertEqual(try store.load().workspaces.count, 1)
    }

    func testAddedWorkspacesGetDistinctPortBlocks() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertNotEqual(model.workspaces[0].portBase, model.workspaces[1].portBase)
    }

    func testRemoveDeletesEntryAndFixesSelection() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let second = model.workspaces[1].id
        model.selectedWorkspaceID = second
        model.removeWorkspace(id: second)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.workspaces[0].id)
        XCTAssertEqual(try store.load().workspaces.count, 1)
    }

    func testRestoresPersistedSessionAndSelectsFirst() {
        let existing = Session(workspaces: [
            Workspace(name: "a", repoPath: "/a", worktreePath: "/a", branch: "",
                      portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, existing.workspaces[0].id)
    }

    func testAddAfterRestoreDoesNotReuseRestoredPortBlock() {
        let existing = Session(workspaces: [
            Workspace(name: "a", repoPath: "/a", worktreePath: "/a", branch: "",
                      portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertNotEqual(model.workspaces[1].portBase, 40000)
    }
}
