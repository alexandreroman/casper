import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class ControlHandlerTests: XCTestCase {
    /// A model seeded with one Git-less space + workspace. `AppModel(sessionStore:)`
    /// alone starts empty (it defaults to `Session()`, not a load from disk), so —
    /// mirroring `AppModelTests`'s `session:` construction pattern — the seeded
    /// `Session` is passed directly to the initializer instead of relying on the
    /// store's file being read back.
    private func seededModel() -> (AppModel, UUID) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt", command: nil))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id)
    }

    func testSetAgentState() {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlSetAgentState(.waiting, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .waiting)
    }

    func testSetProgressSynthesizesTodos() throws {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlSetProgress(total: 4, current: 2, label: "step", for: id))
        let ws = try XCTUnwrap(model.workspace(id: id))
        XCTAssertEqual(ws.progress.completed, 1)
        XCTAssertEqual(ws.progress.total, 4)
        XCTAssertEqual(ws.currentTask, "step")
    }

    func testSetProgressRejectsOutOfRange() {
        let (model, id) = seededModel()
        XCTAssertFalse(model.controlSetProgress(total: 2, current: 5, label: "x", for: id))
    }

    func testClearProgress() {
        let (model, id) = seededModel()
        _ = model.controlSetProgress(total: 3, current: 1, label: "x", for: id)
        XCTAssertTrue(model.controlClearProgress(for: id))
        XCTAssertEqual(model.workspace(id: id)?.progress.total, 0)
    }

    func testRaiseNotificationSetsPendingFlag() {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: nil, for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testResolveByNameAndSelectedFallback() {
        let (model, id) = seededModel()
        XCTAssertEqual(model.controlResolveWorkspaceID(selector: "main"), id)
        XCTAssertEqual(model.controlResolveWorkspaceID(selector: nil), id)  // selected
        XCTAssertNil(model.controlResolveWorkspaceID(selector: "ghost"))
    }

    func testListWorkspaces() {
        let (model, id) = seededModel()
        let list = model.controlListWorkspaces()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, id.uuidString)
        XCTAssertEqual(list.first?.name, "main")
    }
}
