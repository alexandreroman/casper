import XCTest
import CasperCore
import UserNotifications
@testable import CasperUI

@MainActor
final class AgentDetectionTests: XCTestCase {
    /// Every asserted state latches authority — `working` included, since it is a
    /// claim about work the terminal cannot see — and only `idle`/`unknown` hand
    /// the workspace back to the scraper.
    func testAssertedStatesLatchAuthorityWhileIdleReleasesIt() {
        let (model, workspace) = makeSeededModel()
        let id = workspace.id
        XCTAssertFalse(model.explicitAuthority.contains(id), "authority starts released")

        // A detection pass must never latch authority (with no live surface views
        // it is a no-op here, but the point is it never grants authority).
        model.runAgentDetectionTick()
        XCTAssertFalse(model.explicitAuthority.contains(id), "detection must not latch authority")

        XCTAssertTrue(model.controlSetAgentState(.working, for: id))
        XCTAssertTrue(model.explicitAuthority.contains(id), "working outranks the scraper")

        XCTAssertTrue(model.controlSetAgentState(.blocked, for: id))
        XCTAssertTrue(model.explicitAuthority.contains(id), "blocked state latches authority")
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)

        // The session boundary is what a stale `working` now self-heals through:
        // SessionStart reports `idle`, which is the release.
        XCTAssertTrue(model.controlSetAgentState(.idle, for: id))
        XCTAssertFalse(model.explicitAuthority.contains(id), "idle releases the latch")

        XCTAssertTrue(model.controlSetAgentState(.unknown, for: id))
        XCTAssertFalse(model.explicitAuthority.contains(id), "unknown releases the latch")
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
        let model = makeModel(spaces: [space], selecting: primary.id)
        model.deliverNotification = { _, _, _, _ in }

        XCTAssertTrue(model.controlSetAgentState(.done, for: linked.id))
        XCTAssertTrue(model.explicitAuthority.contains(linked.id))

        model.removeWorkspace(id: linked.id)

        XCTAssertNil(model.workspace(id: linked.id), "workspace is gone")
        XCTAssertFalse(model.explicitAuthority.contains(linked.id), "authority pruned on removal")
    }

    /// A detected transition into `blocked` fires a real macOS notification (via
    /// the injected `deliverNotification`) and raises the sidebar attention dot,
    /// with no agent hook involved — this is the notify-without-a-hook feature.
    func testDetectedBlockedDeliversNotificationAndRaisesDot() {
        let (model, workspace) = makeSeededModel()
        let id = workspace.id
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

    /// Captures the message (body) and interruption level a detected transition
    /// from `initial` into `state` passes to `deliverNotification`, failing if it
    /// delivers more than once. Returns nil when nothing is delivered. The workspace
    /// is left unfocused (window not key) so delivery is not suppressed by the focus
    /// check. `initial` is applied before the capture is installed, so only the
    /// transition under test is counted. `initial` must be a silent state: a notifying
    /// one would arm `notificationCooldown` and hide the delivery under test.
    private func deliveredNotification(
        forDetected state: AgentState,
        from initial: AgentState = .idle) -> (body: String, level: UNNotificationInterruptionLevel)? {
        let (model, workspace) = makeSeededModel()
        model.isWindowKey = { false }  // unfocused → delivery not suppressed
        model.setDetectedAgentState(initial, for: workspace.id)
        var delivered: [(body: String, level: UNNotificationInterruptionLevel)] = []
        model.deliverNotification = { _, body, _, level in delivered.append((body, level)) }
        model.setDetectedAgentState(state, for: workspace.id)
        XCTAssertLessThanOrEqual(delivered.count, 1, "one transition delivers at most one notification")
        return delivered.first
    }

    func testDetectedBlockedDeliversActiveNotification() throws {
        let delivered = try XCTUnwrap(deliveredNotification(forDetected: .blocked))
        XCTAssertEqual(delivered.body, "Waiting for your input")
        XCTAssertEqual(delivered.level, .active)
    }

    func testDetectedDoneDeliversPassiveNotification() throws {
        let delivered = try XCTUnwrap(deliveredNotification(forDetected: .done))
        XCTAssertEqual(delivered.body, "Done")
        XCTAssertEqual(delivered.level, .passive)
    }

    func testDetectedErrorDeliversActiveNotification() throws {
        let delivered = try XCTUnwrap(deliveredNotification(forDetected: .error))
        XCTAssertEqual(delivered.body, "Something went wrong")
        XCTAssertEqual(delivered.level, .active)
    }

    func testDetectedWorkingDeliversNothing() {
        XCTAssertNil(deliveredNotification(forDetected: .working))
    }

    /// A seeded workspace already starts idle, so this drives a real working → idle
    /// transition: a same-state write would stop at the change guard.
    func testDetectedIdleDeliversNothing() {
        XCTAssertNil(deliveredNotification(forDetected: .idle, from: .working))
    }

    func testDetectedUnknownDeliversNothing() {
        XCTAssertNil(deliveredNotification(forDetected: .unknown))
    }

    /// The "only on change" guard means a repeated same-state write notifies once.
    func testRepeatedBlockedNotifiesOnce() {
        let (model, workspace) = makeSeededModel()
        let id = workspace.id
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
        let (model, workspace) = makeSeededModel()
        let id = workspace.id  // seeded session selects this workspace
        model.isWindowKey = { true }
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }

        model.setDetectedAgentState(.blocked, for: id)

        XCTAssertEqual(delivered, 0, "no notification is delivered while the workspace is focused")
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false,
                       "the attention dot is suppressed for a focused workspace")
    }
}
