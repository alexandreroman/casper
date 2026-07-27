import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class TeardownHookRunnerTests: XCTestCase {
    /// A minimal model holding one workspace rooted at `worktreePath`. No Git backing
    /// is needed: resolving the hook only reads `.casper.json` from the worktree.
    private func makeModel(worktreePath: String) -> (AppModel, UUID) {
        let ws = Workspace(
            name: "main", worktreePath: worktreePath, branch: "main",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: worktreePath)))
        let space = Space(name: "main", folderPath: worktreePath, isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id)
    }

    /// Two workspaces in one Space: the first is selected (its views mount normally),
    /// the second is not — the shape the off-screen materialization assertions need,
    /// since only a non-selected workspace's views fail to come up on their own.
    private func makeModelWithBackgroundWorkspace() -> (model: AppModel, selected: UUID, background: UUID) {
        let path = NSTemporaryDirectory()
        let selected = Workspace(
            name: "selected", worktreePath: path, branch: "selected",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: path)))
        let background = Workspace(
            name: "background", worktreePath: path, branch: "background",
            portBase: 43000, layout: .leaf(Surface.terminal(cwd: path)))
        let space = Space(
            name: "main", folderPath: path, isGitRepo: false, workspaces: [selected, background])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: selected.id)
        return (AppModel(sessionStore: store, session: session), selected.id, background.id)
    }

    /// Wait for the teardown split to land in `workspaceID` and return its surface id.
    /// `runTeardown` inserts it synchronously, but the task running it only starts on a
    /// later main-queue turn; the poll bound exists so a broken run fails in milliseconds
    /// instead of stalling for the 30 s timeout.
    private func awaitTeardownSplit(
        in model: AppModel, workspace workspaceID: UUID, surfacesBefore: Set<UUID>
    ) async -> UUID? {
        for _ in 0..<400 {
            if let ws = model.workspace(id: workspaceID),
               let split = LayoutTree.surfaceIDs(ws.layout).first(where: { !surfacesBefore.contains($0) }) {
                return split
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the teardown split was never spawned")
        return nil
    }

    /// No `.casper.json` ⇒ no teardown hook ⇒ `runTeardown` returns without suspending
    /// or spawning anything, so the caller prunes right away and destroy keeps its
    /// pre-teardown behavior.
    ///
    /// The teardown-present path is covered by `CloseDeleteWorkspaceTests`, which drives
    /// it headlessly: the split really is spawned, and `completeTeardownSplit` delivers
    /// the child exit through `handleScriptSurfaceExit` — the same entry point
    /// `GhosttySurfaceView.onChildExit` uses in the app. What stays uncovered is the 30 s
    /// timeout fallback, which no test can reach without waiting it out.
    func testReportsNoHookWhenThereIsNoTeardownScript() async throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let (model, workspaceID) = makeModel(worktreePath: dir)
        let workspace = try XCTUnwrap(model.workspace(id: workspaceID))

        let command = model.teardownCommand(for: workspace)
        XCTAssertNil(command, "a worktree without .casper.json has no teardown hook")

        let status = await model.runTeardown(id: workspaceID, command: command)
        XCTAssertEqual(status, .none, "the caller must proceed when there is no teardown hook")
    }

    /// An unknown workspace id cannot get a teardown split, so the wait ends on the
    /// spawn-failure path instead of stalling until the timeout — destroying an
    /// already-gone workspace never hangs.
    func testReportsCouldNotSpawnForUnknownWorkspace() async {
        let (model, _) = makeModel(worktreePath: NSTemporaryDirectory())

        let status = await model.runTeardown(id: UUID(), command: "true")

        XCTAssertEqual(status, .couldNotSpawn, "an unresolvable workspace must not stall the caller")
    }

    /// Deleting a workspace that is NOT the selected one must still run its teardown hook.
    /// A background workspace's views never mount on their own, so without off-screen
    /// materialization no `GhosttySurfaceView` is created, no PTY spawns, the hook command
    /// never runs, and the wait can only end on the 30 s timeout. Headless tests have no
    /// runtime, so we observe the `onMaterializePendingForTest` seam rather than a real PTY.
    func testTeardownInBackgroundWorkspaceMaterializesItsSplitOffScreen() async throws {
        let (model, _, backgroundID) = makeModelWithBackgroundWorkspace()
        let background = try XCTUnwrap(model.workspace(id: backgroundID))
        let surfacesBefore = Set(LayoutTree.surfaceIDs(background.layout))

        var materializedFor: [UUID] = []
        model.onMaterializePendingForTest = { materializedFor.append($0) }

        let teardown = Task { @MainActor in await model.runTeardown(id: backgroundID, command: "exit 0") }
        let spawned = await awaitTeardownSplit(
            in: model, workspace: backgroundID, surfacesBefore: surfacesBefore)
        let split = try XCTUnwrap(spawned)

        XCTAssertTrue(
            materializedFor.contains(backgroundID),
            "a teardown split in a background workspace must be brought up off-screen, "
                + "or the hook never runs and the destroy burns the full timeout")

        // End the hook the way libghostty does, so the run resolves on its child exit.
        model.handleScriptSurfaceExit(split, code: 0)
        let status = await teardown.value
        XCTAssertEqual(status, .succeeded, "the hook must end on its child exit, not on the timeout")
    }

    /// The selected workspace's views mount through the normal path, so its teardown split
    /// needs no nursery — and hosting it off-screen would fight the visible hierarchy for
    /// the same cached view.
    func testTeardownInSelectedWorkspaceDoesNotMaterializeOffScreen() async throws {
        let (model, selectedID, _) = makeModelWithBackgroundWorkspace()
        let selected = try XCTUnwrap(model.workspace(id: selectedID))
        let surfacesBefore = Set(LayoutTree.surfaceIDs(selected.layout))

        var materializedFor: [UUID] = []
        model.onMaterializePendingForTest = { materializedFor.append($0) }

        let teardown = Task { @MainActor in await model.runTeardown(id: selectedID, command: "exit 0") }
        let spawned = await awaitTeardownSplit(
            in: model, workspace: selectedID, surfacesBefore: surfacesBefore)
        let split = try XCTUnwrap(spawned)

        XCTAssertFalse(
            materializedFor.contains(selectedID),
            "the selected workspace mounts its views normally; no off-screen materialization is needed")

        model.handleScriptSurfaceExit(split, code: 0)
        _ = await teardown.value
    }
}
