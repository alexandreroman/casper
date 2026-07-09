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
            portBase: 42000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
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
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        let linked = Workspace(
            name: "feature", worktreePath: "/wt-feature", branch: "feature", portBase: 42210,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt-feature"))), kind: .linked)
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

    /// A detected transition into `blocked` fires a real macOS notification (via
    /// the injected `deliverNotification`) and raises the sidebar attention dot,
    /// with no agent hook involved — this is the notify-without-a-hook feature.
    func testDetectedBlockedDeliversNotificationAndRaisesDot() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // not focused ⇒ dot may raise
        var delivered: [(title: String, body: String, workspaceID: UUID)] = []
        model.deliverNotification = { title, body, workspaceID, _ in
            delivered.append((title, body, workspaceID))
        }

        model.setDetectedAgentState(.blocked, for: id)

        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.title, "main")
        XCTAssertEqual(delivered.first?.body, "Waiting for your input")
        // The third argument is the routing key: the AppDelegate uses it as the
        // notification's request identifier to select the right workspace on tap.
        XCTAssertEqual(delivered.first?.workspaceID, id)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    /// A detected transition into `done` likewise fires a notification.
    func testDetectedDoneDeliversNotification() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        var delivered: [(title: String, body: String)] = []
        model.deliverNotification = { title, body, _, _ in delivered.append((title, body)) }

        model.setDetectedAgentState(.done, for: id)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.body, "Task finished")
    }

    /// Non-attention states (`working`, `idle`) never notify.
    func testDetectedWorkingOrIdleDoesNotNotify() {
        let (model, id) = seededModel()
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }

        model.setDetectedAgentState(.working, for: id)
        model.setDetectedAgentState(.idle, for: id)

        XCTAssertEqual(delivered, 0, "working/idle must not raise a notification")
    }

    /// The "only on change" guard means a repeated same-state write notifies once.
    func testRepeatedBlockedNotifiesOnce() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }

        model.setDetectedAgentState(.blocked, for: id)
        model.setDetectedAgentState(.blocked, for: id)

        XCTAssertEqual(delivered, 1, "no repeat notification while the state is unchanged")
    }

    /// A `blocked` transition while the workspace is focused (selected + window key)
    /// suppresses both the macOS notification and the attention dot — the user is
    /// already looking at it. The focus semantics come for free from
    /// `controlRaiseNotification`.
    func testDetectedBlockedWhileFocusedDoesNotNotifyOrRaiseDot() {
        let (model, id) = seededModel()  // seeded session selects this workspace
        model.isWindowKey = { true }
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }

        model.setDetectedAgentState(.blocked, for: id)

        XCTAssertEqual(delivered, 0, "no notification is delivered while the workspace is focused")
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false,
                       "the attention dot is suppressed for a focused workspace")
    }
}
