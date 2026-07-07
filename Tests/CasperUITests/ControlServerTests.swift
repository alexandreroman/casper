import XCTest
import CasperCore
@testable import CasperUI

/// `handle(_:)` dispatch coverage only — no real socket. `ControlSocketServer`'s
/// own transport is exercised in `CasperCoreTests`; this suite checks that
/// `ControlServer` routes each verb to the right `AppModel.control*` handler.
@MainActor
final class ControlServerTests: XCTestCase {
    /// `ControlServer` only weak-refs its model (matching `DebugServer`'s weak
    /// `provider`, safe in production because `AppDelegate` keeps `AppModel.shared`
    /// retained for the app's lifetime). A test's `AppModel` has no such owner, so
    /// this test case holds the only strong reference — stored here, not in a
    /// local returned from `seededServer()`, so it stays alive for the whole test
    /// method instead of being released as soon as its last local use passes.
    private var model: AppModel?

    /// A model seeded with one Git-less space + workspace, mirroring
    /// `ControlHandlerTests.seededModel()`: `AppModel(sessionStore:)` alone starts
    /// empty (it defaults to `Session()`, not a load from disk), so the seeded
    /// `Session` is passed directly to the initializer.
    private func seededServer() throws -> (ControlServer, UUID) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt", command: nil))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        let model = AppModel(sessionStore: store, session: session)
        self.model = model
        return (ControlServer(socketPath: "/unused-in-dispatch-test.sock", model: model), ws.id)
    }

    func testStatusSetDispatch() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .statusSet, workspace: id.uuidString, state: "blocked"))
        XCTAssertTrue(response.ok)
    }

    func testStatusSetRejectsUnknownState() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .statusSet, workspace: id.uuidString, state: "bogus"))
        XCTAssertFalse(response.ok)
    }

    func testUnresolvableTargetFails() throws {
        let (server, _) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .diffOpen, workspace: "ghost"))
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    func testWorkspaceListDispatch() throws {
        let (server, _) = try seededServer()
        let response = server.handle(ControlCommand(verb: .workspaceList))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspaces?.count, 1)
    }

    func testBrowserCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .browserClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testDiffCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .diffClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }
}
