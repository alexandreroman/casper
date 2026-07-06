import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class AgentDetectionTests: XCTestCase {
    /// A model seeded with one Git-less space + workspace, mirroring
    /// `ControlHandlerTests.seededModel`: the seeded `Session` is passed straight
    /// to the initializer (a bare `AppModel(sessionStore:)` starts empty).
    private func seededModel() -> (AppModel, UUID) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 42000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt", command: nil))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id)
    }

    /// The authority latch: `casper status set` (the explicit CLI path) is the one
    /// and only place authority is granted; the terminal-scraping detector never
    /// grants it.
    func testExplicitSetLatchesAuthorityDetectionDoesNot() {
        let (model, id) = seededModel()
        XCTAssertFalse(model.isUnderExplicitAuthority(id), "authority starts released")

        // A detection pass must never latch authority (with no live surface views
        // it is a no-op here, but the point is it never grants authority).
        model.runAgentDetectionTick()
        XCTAssertFalse(model.isUnderExplicitAuthority(id), "detection must not latch authority")

        XCTAssertTrue(model.controlSetAgentState(.blocked, for: id))
        XCTAssertTrue(model.isUnderExplicitAuthority(id), "explicit set latches authority")
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
    }

    /// Removing a workspace prunes its entry from the transient authority map, so
    /// those maps don't grow unbounded over a long session. (The control-destroy
    /// path funnels through the same `removeWorkspace`, so covering it here suffices.)
    func testRemoveWorkspacePrunesExplicitAuthority() {
        let primary = Workspace(
            name: "main", worktreePath: "/wt", branch: "main", portBase: 42200,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt", command: nil))))
        let linked = Workspace(
            name: "feature", worktreePath: "/wt-feature", branch: "feature", portBase: 42210,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt-feature", command: nil))), kind: .linked)
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [primary, linked])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let model = AppModel(sessionStore: SessionStore(fileURL: url),
                             session: Session(spaces: [space], selectedWorkspaceID: primary.id))

        XCTAssertTrue(model.controlSetAgentState(.working, for: linked.id))
        XCTAssertTrue(model.isUnderExplicitAuthority(linked.id))

        model.removeWorkspace(id: linked.id)

        XCTAssertNil(model.workspace(id: linked.id), "workspace is gone")
        XCTAssertFalse(model.isUnderExplicitAuthority(linked.id), "authority pruned on removal")
    }
}
