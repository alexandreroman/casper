import XCTest
import CasperCore
@testable import CasperUI

// MARK: - DockAttention itself

/// A scriptable `DockAttentionBackend`, so `DockAttention`'s request-id latch can be
/// observed without a running `NSApplication`.
@MainActor
private final class FakeDockAttentionBackend: DockAttentionBackend {
    var isApplicationActive = false
    private(set) var requestedIDs: [Int] = []
    private(set) var cancelledIDs: [Int] = []
    private(set) var badgeLabels: [String?] = []

    func requestAttention() -> Int? {
        // Distinct ids, so a cancel can be traced back to the request it releases.
        let id = requestedIDs.count + 1
        requestedIDs.append(id)
        return id
    }

    func cancelAttention(_ id: Int) {
        cancelledIDs.append(id)
    }

    func setBadgeLabel(_ label: String?) {
        badgeLabels.append(label)
    }
}

@MainActor
final class DockAttentionLatchTests: XCTestCase {
    func testASecondBounceIsANoOpWhileOneIsOutstanding() {
        let backend = FakeDockAttentionBackend()
        let dock = DockAttention(backend: backend)

        dock.bounce()
        dock.bounce()

        XCTAssertEqual(backend.requestedIDs, [1], "repeated notifications must not stack up requests")
    }

    func testCancellingReleasesTheOutstandingRequestAndRearmsTheBounce() {
        let backend = FakeDockAttentionBackend()
        let dock = DockAttention(backend: backend)
        dock.bounce()

        dock.cancelBounce()

        XCTAssertEqual(backend.cancelledIDs, [1], "the request is cancelled under the id it was handed")
        // The latch is clear again, so the next notification starts a fresh request.
        dock.bounce()
        XCTAssertEqual(backend.requestedIDs, [1, 2])
    }

    func testCancellingWithoutAnOutstandingBounceDoesNothing() {
        let backend = FakeDockAttentionBackend()
        let dock = DockAttention(backend: backend)

        dock.cancelBounce()

        XCTAssertTrue(backend.cancelledIDs.isEmpty)
    }

    /// The active app must neither request attention (AppKit's own contract) nor latch
    /// one: nothing would release that latch — `applicationDidBecomeActive` never fires
    /// for an app that never left the front — and it would swallow the next real bounce.
    func testBouncingWhileTheAppIsActiveRequestsNothingAndLeavesTheLatchClear() {
        let backend = FakeDockAttentionBackend()
        let dock = DockAttention(backend: backend)
        backend.isApplicationActive = true

        dock.bounce()

        XCTAssertTrue(backend.requestedIDs.isEmpty, "an active app must not request attention")
        // Backgrounded, the very next notification still bounces.
        backend.isApplicationActive = false
        dock.bounce()
        XCTAssertEqual(backend.requestedIDs, [1])
    }

    func testTheBadgeCarriesTheCountAndIsClearedAtZero() {
        let backend = FakeDockAttentionBackend()
        let dock = DockAttention(backend: backend)

        dock.updateBadge(count: 3)
        dock.updateBadge(count: 0)

        XCTAssertEqual(backend.badgeLabels, ["3", nil])
    }
}

// MARK: - The AppModel wiring

/// Records what `AppModel` asks of the Dock, so the wiring can be asserted without a
/// running `NSApplication`.
///
/// Deliberately dumb: it counts calls and nothing more. `DockAttention`'s own "one
/// outstanding request at a time" latch is tested against it directly
/// (`DockAttentionLatchTests`) — mirroring it here would only assert the spy.
@MainActor
private final class DockAttentionSpy: DockAttentionPresenting {
    private(set) var bounceCalls = 0
    private(set) var cancelCalls = 0
    /// Every count pushed to the badge, in order.
    private(set) var badges: [Int] = []

    /// The count the badge last showed, or nil while `updateBadge` was never called.
    var badge: Int? { badges.last }

    func bounce() {
        bounceCalls += 1
    }

    func cancelBounce() {
        cancelCalls += 1
    }

    func updateBadge(count: Int) {
        badges.append(count)
    }
}

@MainActor
final class DockAttentionTests: XCTestCase {
    /// A model seeded with one Git-less Space holding a primary and two linked
    /// workspaces, mirroring `AgentDetectionTests.seededModel`: the seeded `Session`
    /// is passed straight to the initializer (a bare `AppModel(sessionStore:)` starts
    /// empty). The two linked workspaces are what the badge counts across, and being
    /// linked is also what makes them removable.
    private func seededModel() -> (AppModel, DockAttentionSpy, UUID, UUID) {
        let primary = Workspace(
            name: "main", worktreePath: "/wt", branch: "main", portBase: 43000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        let first = Workspace(
            name: "feature-a", worktreePath: "/wt-a", branch: "feature-a", portBase: 43010,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt-a"))), kind: .linked)
        let second = Workspace(
            name: "feature-b", worktreePath: "/wt-b", branch: "feature-b", portBase: 43020,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt-b"))), kind: .linked)
        let space = Space(
            name: "main", folderPath: "/wt", isGitRepo: false,
            workspaces: [primary, first, second])
        let (model, spy) = makeModel(seededWith: [space], selecting: primary.id)
        return (model, spy, first.id, second.id)
    }

    /// An `AppModel` over a throwaway session file, with the Dock spied on and the
    /// window reported as not key — so every raised notification arms — and the macOS
    /// notification mocked out, to avoid the `UNUserNotificationCenter` abort in a
    /// bundle-less test.
    private func makeModel(
        seededWith spaces: [Space], selecting selected: UUID?
    ) -> (AppModel, DockAttentionSpy) {
        let model = makeModel(spaces: spaces, selecting: selected)
        model.isWindowKey = { false }
        model.deliverNotification = { _, _, _, _ in }
        let spy = DockAttentionSpy()
        model.dockAttention = spy
        return (model, spy)
    }

    func testRaisingOnUnfocusedWorkspaceBouncesAndBadgesOne() {
        let (model, spy, first, _) = seededModel()

        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))

        XCTAssertEqual(spy.bounceCalls, 1, "an armed notification asks for the bounce")
        XCTAssertEqual(spy.cancelCalls, 0, "an unread must not cancel the bounce")
        XCTAssertEqual(spy.badge, 1)
    }

    func testSecondUnreadTakesBadgeToTwoAndAsksForTheBounceAgain() {
        let (model, spy, first, second) = seededModel()

        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: second))

        XCTAssertEqual(spy.badge, 2)
        // Every armed notification asks; keeping a single request outstanding is
        // `DockAttention`'s job, not `AppModel`'s (see `DockAttentionLatchTests`).
        XCTAssertEqual(spy.bounceCalls, 2)
        XCTAssertEqual(spy.cancelCalls, 0)
    }

    func testFocusingOneWorkspaceDropsBadgeToOneAndKeepsTheBounce() {
        let (model, spy, first, second) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: second))

        // Focus the first one: selected while the window is key.
        model.selectWorkspace(first)
        model.isWindowKey = { true }
        model.clearNotificationForFocusedWorkspace()

        XCTAssertEqual(model.workspace(id: first)?.pendingNotification, false)
        XCTAssertEqual(spy.badge, 1, "the second workspace is still unread")
        XCTAssertEqual(spy.cancelCalls, 0, "a remaining unread keeps the bounce alive")
    }

    func testClearingTheLastUnreadClearsTheBadgeAndCancelsTheBounce() {
        let (model, spy, first, _) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))

        model.selectWorkspace(first)
        model.isWindowKey = { true }
        model.clearNotificationForFocusedWorkspace()

        XCTAssertEqual(spy.badge, 0, "a zero count clears the badge")
        XCTAssertEqual(spy.cancelCalls, 1, "a badge-free Dock icon must not stay bouncing")
    }

    func testResumingWorkClearsTheBadgeAndCancelsTheBounce() {
        let (model, spy, first, _) = seededModel()
        XCTAssertTrue(model.controlSetAgentState(.done, for: first))
        XCTAssertEqual(spy.badge, 1)

        // A `done → working` resume retracts the notification the agent itself made stale.
        XCTAssertTrue(model.controlSetAgentState(.working, for: first))

        XCTAssertEqual(model.workspace(id: first)?.pendingNotification, false)
        XCTAssertEqual(spy.badge, 0)
        XCTAssertEqual(spy.cancelCalls, 1)
    }

    func testRaisingOnAFocusedWorkspaceNeitherBouncesNorBadges() {
        let (model, spy, first, _) = seededModel()
        model.selectWorkspace(first)
        model.isWindowKey = { true }

        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))

        XCTAssertEqual(model.workspace(id: first)?.pendingNotification, false)
        XCTAssertEqual(spy.bounceCalls, 0)
        XCTAssertNil(spy.badge, "the Dock is left untouched when nothing was armed")
    }

    /// What `applicationDidBecomeActive` and `applicationDidResignActive` both do: the
    /// bounce is answered by coming back, the badge is not — it counts unread
    /// workspaces, and each one clears on its own terms.
    func testReleasingTheBounceLeavesTheBadgeAlone() {
        let (model, spy, first, _) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))
        XCTAssertEqual(spy.badges, [1])

        model.releaseDockBounce()

        XCTAssertEqual(spy.cancelCalls, 1)
        XCTAssertEqual(spy.badges, [1], "the unread survives the activation")
    }

    func testRemovingAWorkspaceCarryingAnUnreadRefreshesTheBadge() {
        let (model, spy, first, second) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: second))
        XCTAssertEqual(spy.badge, 2)

        model.removeWorkspace(id: second)

        XCTAssertNil(model.workspace(id: second), "workspace is gone")
        XCTAssertEqual(spy.badge, 1, "a deleted workspace's unread must not linger")
        XCTAssertEqual(spy.cancelCalls, 0)
    }

    func testRemovingTheLastUnreadWorkspaceCancelsTheBounce() {
        let (model, spy, first, _) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))

        model.removeWorkspace(id: first)

        XCTAssertEqual(spy.badge, 0)
        XCTAssertEqual(spy.cancelCalls, 1)
    }

    func testRemovingASpaceCarryingAnUnreadRefreshesTheBadge() {
        let (model, spy, first, _) = seededModel()
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: first))
        guard let spaceID = model.spaces.first?.id else { return XCTFail("expected a seeded Space") }

        model.removeSpace(id: spaceID)

        XCTAssertEqual(spy.badge, 0)
        XCTAssertEqual(spy.cancelCalls, 1)
    }

    /// The third workspace-drop path, and the subtlest: `addSpace` absorbs the Spaces
    /// rooted at the repository's worktrees, and `reunify` retires whichever of their
    /// workspaces cannot come along. That retirement happens *before* the single write
    /// to `spaces`, so the badge can only be refreshed by `addSpace` afterwards.
    ///
    /// The setup is the one case where a workspace is dropped rather than moved: a
    /// Space rooted at a linked worktree also holds a workspace on the repository's own
    /// working tree, which is where the new Space's primary lands. Adding a
    /// *subdirectory* of that working tree is what reaches the case — adding the
    /// working tree itself would be recognized as already open.
    func testAbsorbingASpaceDropsItsWorkspaceUnreadFromTheBadge() {
        let repo = "/repo"
        let worktree = "/repo-wt"
        let commonDir = "/repo/.git"
        // The Space rooted at the linked worktree, holding both the worktree itself and
        // a stray workspace on the repository's working tree.
        let moved = Workspace(
            name: "wt", worktreePath: worktree, branch: "feature", portBase: 43010,
            layout: .leaf(Surface(kind: .terminal(cwd: worktree))))
        let dropped = Workspace(
            name: "stray", worktreePath: repo, branch: "main", portBase: 43020,
            layout: .leaf(Surface(kind: .terminal(cwd: repo))), kind: .linked)
        let space = Space(
            name: "wt", folderPath: worktree, isGitRepo: true, workspaces: [moved, dropped])
        let (model, spy) = makeModel(seededWith: [space], selecting: moved.id)
        let probe: (URL) -> WorkspaceFactory.GitInfo? = { url in
            WorkspaceFactory.GitInfo(
                canonicalPath: url.path == worktree ? worktree : repo,
                branch: url.path == worktree ? "feature" : "main", remoteURL: nil,
                commonDirPath: commonDir, isLinkedWorktree: url.path == worktree)
        }
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: moved.id))
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: dropped.id))
        XCTAssertEqual(spy.badge, 2)

        model.addSpace(folderURL: URL(fileURLWithPath: repo + "/sub"), probe: probe)

        XCTAssertNil(model.workspace(id: dropped.id), "the stray workspace was retired")
        XCTAssertEqual(model.workspace(id: moved.id)?.pendingNotification, true)
        XCTAssertEqual(spy.badge, 1, "a retired workspace's unread must not linger")
    }
}
