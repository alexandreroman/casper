import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class TeardownHookRunnerTests: XCTestCase {
    /// A minimal model holding one workspace rooted at `worktreePath`. No Git backing
    /// is needed: `runTeardownThenPrune` only reads `.casper.json` from the worktree.
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

    /// No `.casper.json` ⇒ no teardown hook ⇒ the prune runs inline in the caller's
    /// stack, before the call returns, so destroy keeps its pre-teardown behavior.
    ///
    /// The teardown-present path (spawning the visible split, the 30 s timeout
    /// fallback, and the exactly-once latch shared by the child-exit and the timeout)
    /// can only run against a live libghostty surface, so it is covered by manual
    /// verification in B4-2 rather than a fragile unit test here.
    func testRunsPruneSynchronouslyWhenNoTeardownScript() throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let (model, workspaceID) = makeModel(worktreePath: dir)

        var pruned = false
        model.runTeardownThenPrune(id: workspaceID) { pruned = true }

        XCTAssertTrue(pruned, "prune must run synchronously when there is no teardown hook")
    }

    /// An unknown workspace id short-circuits to the same synchronous prune (the
    /// guard's early return), so destroying an already-gone workspace never hangs.
    func testRunsPruneSynchronouslyForUnknownWorkspace() {
        let (model, _) = makeModel(worktreePath: NSTemporaryDirectory())

        var pruned = false
        model.runTeardownThenPrune(id: UUID()) { pruned = true }

        XCTAssertTrue(pruned, "prune must run synchronously when the workspace cannot be resolved")
    }
}
