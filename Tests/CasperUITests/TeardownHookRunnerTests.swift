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
}
