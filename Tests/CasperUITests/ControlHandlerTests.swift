import XCTest
import CasperCore
import Clibgit2
@testable import CasperGit
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

    /// Initialize a repo at `path` and create one commit on it, via libgit2 only
    /// (no `git` binary). Inlined from `Tests/CasperGitTests/GitFixture.swift`,
    /// which this target cannot import: that fixture lives in the CasperGitTests
    /// target, whereas `CasperUITests` links `CasperGit`/`Clibgit2` directly (see
    /// Package.swift) without seeing that target's test sources.
    private func makeRepo(at path: String) throws {
        let repo = try Repository.initialize(atPath: path)

        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "casper fixture\n".write(to: readme, atomically: true, encoding: .utf8)

        var index: OpaquePointer?
        XCTAssertEqual(git_repository_index(&index, repo.pointer), 0)
        defer { git_index_free(index) }
        XCTAssertEqual(git_index_add_bypath(index, "README.md"), 0)
        XCTAssertEqual(git_index_write(index), 0)

        var treeOid = git_oid()
        XCTAssertEqual(git_index_write_tree(&treeOid, index), 0)
        var tree: OpaquePointer?
        XCTAssertEqual(git_tree_lookup(&tree, repo.pointer, &treeOid), 0)
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        XCTAssertEqual(git_signature_now(&signature, "Casper Test", "test@casper.local"), 0)
        defer { git_signature_free(signature) }

        var commitOid = git_oid()
        XCTAssertEqual(git_commit_create(
            &commitOid, repo.pointer, "HEAD",
            signature, signature, nil, "Initial commit", tree, 0, nil), 0)
    }

    /// Seeds a Git-backed model: a real temp repo with one commit, opened as a
    /// Space whose primary workspace's `branch` is left empty. `primaryBranch`
    /// names the scenario for the caller but is never assigned to the workspace:
    /// libgit2's default branch after `initialize` depends on the host's
    /// `git config init.defaultBranch` (`main` vs `master`), so hardcoding either
    /// would be flaky. An empty branch makes `createLinkedWorkspace`'s `base`
    /// resolve to `nil`, which `WorktreeManager.create` always accepts as "fork
    /// from HEAD" — the same outcome without guessing the branch name.
    private func seededGitModel(primaryBranch: String) throws -> (AppModel, UUID, String) {
        let repoPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-ctrl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        try makeRepo(at: repoPath)

        let ws = Workspace(
            name: "main", worktreePath: repoPath, branch: "",
            portBase: 41000, layout: .leaf(Surface.terminal(cwd: repoPath)))
        let space = Space(name: "main", folderPath: repoPath, isGitRepo: true, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id, repoPath)
    }

    func testOpenTerminalAddsSurface() throws {
        let (model, id) = seededModel()
        let before = model.workspace(id: id).map { LayoutTree.surfaceIDs($0.layout).count } ?? 0
        XCTAssertTrue(model.controlOpenTerminal(in: id))
        let after = model.workspace(id: id).map { LayoutTree.surfaceIDs($0.layout).count } ?? 0
        XCTAssertEqual(after, before + 1)
    }

    func testOpenTerminalHonorsCommandAndCwd() throws {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlOpenTerminal(in: id, command: "npm test", cwd: "/some/dir"))
        let ws = try XCTUnwrap(model.workspace(id: id))
        let match = surfaces(in: ws.layout).contains { surface in
            if case .terminal(let cwd, let command) = surface.kind {
                return cwd == "/some/dir" && command == "npm test"
            }
            return false
        }
        XCTAssertTrue(match, "expected a terminal surface with the given cwd and command")
    }

    /// Collect every leaf surface in a layout, depth-first (the test target has no
    /// public surface-by-id accessor, so it walks the public `LayoutNode` directly).
    private func surfaces(in node: LayoutNode) -> [Surface] {
        switch node {
        case .leaf(let surface):
            return [surface]
        case .split(_, let children, _):
            return children.flatMap { surfaces(in: $0) }
        }
    }

    func testOpenBrowserLoadsInspectorBrowserAndSelectsTab() throws {
        let (model, id) = seededModel()
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(model.controlOpenBrowser(url: url, in: id))
        let ws = try XCTUnwrap(model.workspace(id: id))
        XCTAssertEqual(ws.inspector.tab, .browser)
        XCTAssertFalse(ws.inspector.collapsed)
        if case .browser(let u) = ws.inspector.browser.kind { XCTAssertEqual(u, url) }
        else { XCTFail("inspector browser surface is not a browser kind") }
    }

    func testShowDiffSelectsInspectorTab() throws {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlShowDiff(in: id))
        XCTAssertEqual(model.workspace(id: id)?.inspector.tab, .diff)
        XCTAssertEqual(model.workspace(id: id)?.inspector.collapsed, false)
    }

    func testCreateWorkspaceMakesWorktreeAndReturnsInfo() throws {
        let (model, primaryID, _) = try seededGitModel(primaryBranch: "main")
        switch model.controlCreateWorkspace(inSpaceOf: primaryID, branch: "feature-x", base: nil) {
        case .success(let info):
            XCTAssertEqual(info.branch, "feature-x")
            XCTAssertTrue(model.allWorkspaces.contains { $0.id.uuidString == info.id })
        case .failure(let error):
            XCTFail("expected success, got \(error.message)")
        }
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

    func testRaiseNotificationOnSelectedButBackgroundedSetsBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // selected, but app not frontmost
        XCTAssertTrue(model.controlRaiseNotification(message: nil, for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testRaiseNotificationOnFocusedWorkspaceSkipsBubble() {
        let (model, id) = seededModel()   // id is the selected workspace
        model.isWindowKey = { true }      // and the window is key → focused
        XCTAssertTrue(model.controlRaiseNotification(message: nil, for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testRaiseNotificationOnUnselectedWorkspaceSetsBubble() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()  // some OTHER workspace is selected
        model.isWindowKey = { true }        // app frontmost, but target not selected
        XCTAssertTrue(model.controlRaiseNotification(message: nil, for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testForegroundClearsBubbleOnFocusedWorkspace() {
        let (model, id) = seededModel()          // id is selected
        model.isWindowKey = { false }            // app backgrounded
        _ = model.controlRaiseNotification(message: nil, for: id)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        model.isWindowKey = { true }             // app returns to foreground
        model.clearNotificationForFocusedWorkspace()
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testForegroundDoesNotClearBubbleWhenWindowNotKey() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        _ = model.controlRaiseNotification(message: nil, for: id)
        model.clearNotificationForFocusedWorkspace()   // still backgrounded
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testClearDoesNotTouchUnselectedWorkspaceBubble() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()       // a different workspace is selected
        model.isWindowKey = { true }
        _ = model.controlRaiseNotification(message: nil, for: id)  // id not selected → bubble set
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        model.clearNotificationForFocusedWorkspace()               // clears only the selected one
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testSelectingWorkspaceClearsItsBubbleWhenKey() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        _ = model.controlRaiseNotification(message: nil, for: id)  // bubble set while backgrounded
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        model.isWindowKey = { true }             // app frontmost
        model.selectWorkspace(id)                // (re)selecting the focused workspace clears it
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
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
