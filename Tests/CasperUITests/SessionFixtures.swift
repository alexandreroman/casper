import Foundation
import XCTest
import CasperCore
@testable import CasperUI

/// Fixtures shared by every test case in this target.
///
/// `SessionStore` writes a real file and `AppModel` saves through it on a
/// background queue, so seeding a model always leaves something behind on disk —
/// as does a Git fixture, which is a real libgit2 checkout. Routing every test
/// through these helpers is what keeps the `addTeardownBlock` cleanup in one
/// place rather than one forgettable copy per test case.
extension XCTestCase {
    /// A `SessionStore` over a throwaway JSON file, removed after the test. The
    /// URL is returned for the tests that read the file back.
    func makeTemporarySessionStore() -> (store: SessionStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SessionStore(fileURL: url), url)
    }

    /// A fresh temp directory on disk, removed after the test. `prefix` only makes
    /// a stranded directory traceable back to the suite that made it.
    ///
    /// It sits one level inside a container that teardown removes, because Casper
    /// puts a linked worktree *beside* its repository: deleting the repo directory
    /// alone would leave every worktree a test created behind.
    func makeTemporaryDirectory(prefix: String = "casper-test") -> URL {
        let name = "\(prefix)-\(UUID().uuidString)"
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let dir = container.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return dir
    }

    /// An `AppModel` over `spaces`, with `selected` as the current workspace.
    ///
    /// `AppModel(sessionStore:)` alone starts empty — it defaults to `Session()`
    /// rather than loading from disk — so a seeded `Session` has to be handed
    /// straight to the initializer.
    @MainActor
    func makeModel(spaces: [Space] = [], selecting selected: UUID? = nil) -> AppModel {
        makeModel(
            store: makeTemporarySessionStore().store,
            session: Session(spaces: spaces, selectedWorkspaceID: selected))
    }

    /// An `AppModel` over a store the caller already made — the shape the tests that
    /// read the session file back need.
    @MainActor
    func makeModel(store: SessionStore, session: Session = Session()) -> AppModel {
        let model = AppModel(sessionStore: store, session: session)
        // Saves are debounced onto a background queue, so a write this test schedules
        // can land after teardown has deleted the file. Teardown blocks run
        // last-registered-first, so draining here precedes the store's own removal
        // and leaves nothing to recreate it.
        addTeardownBlock { await MainActor.run { model.flushPendingSave() } }
        return model
    }

    /// An `AppModel` holding one Git-less Space with a single selected workspace —
    /// the minimum shape most handler and layout tests need.
    @MainActor
    func makeSeededModel(
        worktreePath: String = "/wt",
        portBase: Int = 40000,
        inspector: InspectorState = InspectorState()
    ) -> (model: AppModel, workspace: Workspace) {
        let workspace = Workspace(
            name: "main", worktreePath: worktreePath, branch: "main",
            portBase: portBase, layout: .leaf(Surface.terminal(cwd: worktreePath)),
            inspector: inspector)
        let space = Space(
            name: "main", folderPath: worktreePath, isGitRepo: false, workspaces: [workspace])
        return (makeModel(spaces: [space], selecting: workspace.id), workspace)
    }

    /// Poll `condition` on the main actor until it holds, failing at `timeout`.
    /// Preferred over a fixed delay: a green run costs only what the work actually
    /// takes, and a broken one reports a timeout instead of a stale assertion.
    @MainActor
    func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return XCTFail("condition not met within \(timeout)s", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
