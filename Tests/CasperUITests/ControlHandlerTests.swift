import XCTest
import CasperCore
import Clibgit2
import UserNotifications
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
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
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
        let info = try XCTUnwrap(model.controlOpenTerminal(in: id))
        let after = model.workspace(id: id).map { LayoutTree.surfaceIDs($0.layout).count } ?? 0
        XCTAssertEqual(after, before + 1)
        let ws = try XCTUnwrap(model.workspace(id: id))
        let newID = try XCTUnwrap(UUID(uuidString: info.id))
        XCTAssertTrue(LayoutTree.surfaceIDs(ws.layout).contains(newID))
        // No cwd passed → the resolved cwd is the workspace's worktree.
        XCTAssertEqual(info.cwd, ws.worktreePath)
    }

    func testOpenTerminalHonorsCwd() throws {
        let (model, id) = seededModel()
        let info = try XCTUnwrap(model.controlOpenTerminal(in: id, command: "npm test", cwd: "/some/dir"))
        XCTAssertEqual(info.cwd, "/some/dir")
        let ws = try XCTUnwrap(model.workspace(id: id))
        let match = surfaces(in: ws.layout).contains { surface in
            if case .terminal(let cwd) = surface.kind { return cwd == "/some/dir" }
            return false
        }
        XCTAssertTrue(match, "expected a terminal surface with the given cwd")
    }

    func testListTerminalsReportsOpenTerminals() throws {
        let (model, id) = seededModel()
        XCTAssertEqual(model.controlListTerminals(in: id).count, 1)  // the seeded leaf
        XCTAssertNotNil(model.controlOpenTerminal(in: id, command: "htop", cwd: "/tmp"))
        let terminals = model.controlListTerminals(in: id)
        XCTAssertEqual(terminals.count, 2)
        XCTAssertTrue(
            terminals.contains { $0.cwd == "/tmp" },
            "expected a listed terminal with the opened cwd")
    }

    func testCloseTerminalRemovesItById() throws {
        let (model, id) = seededModel()
        // Open a second terminal first: closing the LAST surface would tear down
        // the workspace, so keep one alive to assert it survives.
        XCTAssertNotNil(model.controlOpenTerminal(in: id))
        let terminals = model.controlListTerminals(in: id)
        XCTAssertEqual(terminals.count, 2)
        let victim = try XCTUnwrap(terminals.first)
        XCTAssertTrue(model.controlCloseTerminal(in: id, terminalID: victim.id))
        let remaining = model.controlListTerminals(in: id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(remaining.contains { $0.id == victim.id })
    }

    func testCloseTerminalRejectsUnknownAndMalformedIds() throws {
        let (model, id) = seededModel()
        XCTAssertNotNil(model.controlOpenTerminal(in: id))  // keep at least two alive
        XCTAssertFalse(model.controlCloseTerminal(in: id, terminalID: UUID().uuidString))  // random UUID
        XCTAssertFalse(model.controlCloseTerminal(in: id, terminalID: "not-a-uuid"))       // non-UUID
        XCTAssertEqual(model.controlListTerminals(in: id).count, 2)  // nothing closed
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

    /// A second `controlOpenBrowser` with a different URL must navigate the
    /// coordinator that was already created for the first open — it must not keep
    /// showing the previous page. Uses `data:` URLs so the load resolves locally
    /// (no network) and the navigation delegate commits, matching how
    /// `BrowserCaptureTests` exercises a live `WKWebView`.
    func testSecondOpenBrowserNavigatesExistingCoordinator() async throws {
        let (model, id) = seededModel()
        let firstURL = try XCTUnwrap(URL(string: "data:text/html,%3Ch1%3Eone%3C/h1%3E"))
        let secondURL = try XCTUnwrap(URL(string: "data:text/html,%3Ch1%3Etwo%3C/h1%3E"))

        // First open, then force-create the coordinator the way the SwiftUI view
        // would on first render. It loads `firstURL` at init; wait for that commit.
        // Compare against the coordinator's own committed string rather than
        // reconstructing it, so any WebKit URL normalization can't skew the test.
        XCTAssertTrue(model.controlOpenBrowser(url: firstURL, in: id))
        let firstSurface = try XCTUnwrap(model.workspace(id: id)).inspector.browser
        let coordinator = try XCTUnwrap(model.browserCoordinator(for: firstSurface))
        try await waitUntil { !coordinator.address.isEmpty }
        let firstCommitted = coordinator.address

        // Second open with a different URL. The coordinator already exists, so the
        // surface id is reused and the same instance must be navigated away from the
        // first page — before the fix, no navigation was triggered and this timed out.
        XCTAssertTrue(model.controlOpenBrowser(url: secondURL, in: id))
        let secondSurface = try XCTUnwrap(model.workspace(id: id)).inspector.browser
        XCTAssertEqual(secondSurface.id, firstSurface.id, "surface id must be reused across opens")
        XCTAssertTrue(
            model.browserCoordinator(for: secondSurface) === coordinator,
            "the cached coordinator must be preserved, not recreated")

        try await waitUntil { coordinator.address != firstCommitted }
    }

    /// Polls `condition` on the main actor until it holds or `timeout` elapses,
    /// yielding between checks so pending `WKWebView` navigation callbacks can run.
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return XCTFail("condition not met within \(timeout)s", file: file, line: line)
            }
            try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
        }
    }

    func testCloseBrowserCollapsesWhenBrowserTabActive() throws {
        let (model, id) = seededModel()
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(model.controlOpenBrowser(url: url, in: id))
        XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

        XCTAssertTrue(model.controlCloseBrowser(in: id))
        XCTAssertTrue(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)
    }

    func testCloseBrowserNoOpsWhenDiffTabActive() throws {
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .success = model.controlOpenDiff(in: id) else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

        XCTAssertTrue(model.controlCloseBrowser(in: id))  // still succeeds
        let ws = try XCTUnwrap(model.workspace(id: id))
        XCTAssertEqual(ws.inspector.tab, .diff)   // untouched
        XCTAssertFalse(ws.inspector.collapsed)    // untouched — diff still showing
    }

    func testCloseBrowserFailsForUnknownWorkspace() {
        let (model, _) = seededModel()
        XCTAssertFalse(model.controlCloseBrowser(in: UUID()))
    }

    func testCloseDiffCollapsesWhenDiffTabActive() throws {
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .success = model.controlOpenDiff(in: id) else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

        XCTAssertTrue(model.controlCloseDiff(in: id))
        XCTAssertTrue(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)
    }

    func testCloseDiffNoOpsWhenBrowserTabActive() throws {
        let (model, id) = seededModel()
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(model.controlOpenBrowser(url: url, in: id))
        XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

        XCTAssertTrue(model.controlCloseDiff(in: id))  // still succeeds
        let ws = try XCTUnwrap(model.workspace(id: id))
        XCTAssertEqual(ws.inspector.tab, .browser)  // untouched
        XCTAssertFalse(ws.inspector.collapsed)      // untouched — browser still showing
    }

    func testCloseDiffFailsForUnknownWorkspace() {
        let (model, _) = seededModel()
        XCTAssertFalse(model.controlCloseDiff(in: UUID()))
    }

    func testOpenDiffSelectsInspectorTab() throws {
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .success = model.controlOpenDiff(in: id) else {
            return XCTFail("expected success")
        }
        XCTAssertNil(model.diffScrollTarget)
        XCTAssertEqual(model.workspace(id: id)?.inspector.tab, .diff)
        XCTAssertEqual(model.workspace(id: id)?.inspector.collapsed, false)
    }

    func testOpenDiffWithExistingFileSetsScrollTarget() throws {
        // `makeRepo` writes a real `README.md` into the fixture worktree, so the
        // on-disk existence check passes for it.
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .success = model.controlOpenDiff(in: id, file: "README.md") else {
            return XCTFail("expected success")
        }
        let first = try XCTUnwrap(model.diffScrollTarget)
        XCTAssertEqual(first.workspaceID, id)
        XCTAssertEqual(first.file, "README.md")

        // A repeat request for the same file must produce a fresh nonce so the
        // view re-scrolls even though the file argument is unchanged.
        guard case .success = model.controlOpenDiff(in: id, file: "README.md") else {
            return XCTFail("expected success")
        }
        let second = try XCTUnwrap(model.diffScrollTarget)
        XCTAssertEqual(second.file, "README.md")
        XCTAssertNotEqual(second.nonce, first.nonce)
    }

    func testOpenDiffWithMissingFileFails() throws {
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .failure(let error) = model.controlOpenDiff(in: id, file: "does-not-exist.swift") else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("does not exist"), "got: \(error.message)")
        XCTAssertNil(model.diffScrollTarget)
    }

    func testOpenDiffWithEscapingFileFails() throws {
        let (model, id, _) = try seededGitModel(primaryBranch: "main")
        guard case .failure(let error) = model.controlOpenDiff(in: id, file: "../escape.txt") else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("outside the workspace"), "got: \(error.message)")
        XCTAssertNil(model.diffScrollTarget)
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

    func testCreateWorkspaceHonorsCommand() throws {
        let (model, primaryID, _) = try seededGitModel(primaryBranch: "main")
        switch model.controlCreateWorkspace(
            inSpaceOf: primaryID, branch: "feature-cmd", base: nil, command: "npm test") {
        case .success(let info):
            let ws = try XCTUnwrap(model.workspace(id: try XCTUnwrap(UUID(uuidString: info.id))))
            let hasTerminal = surfaces(in: ws.layout).contains { surface in
                if case .terminal = surface.kind { return true }
                return false
            }
            XCTAssertTrue(hasTerminal, "expected the new workspace to have a terminal surface")
        case .failure(let error):
            XCTFail("expected success, got \(error.message)")
        }
    }

    func testDeleteWorkspaceRemovesWorktreeFolderAndBranch() throws {
        let (model, primaryID, repoPath) = try seededGitModel(primaryBranch: "main")
        let info: ControlWorkspaceInfo
        switch model.controlCreateWorkspace(inSpaceOf: primaryID, branch: "feature-del", base: nil) {
        case .success(let created): info = created
        case .failure(let error): return XCTFail("setup failed: \(error.message)")
        }
        let linkedID = try XCTUnwrap(UUID(uuidString: info.id))
        // Precondition: the linked worktree folder and its branch exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(info.branch))

        var result: Result<Void, AppModel.WorkspaceDeleteError>?
        model.controlDeleteWorkspace(id: linkedID) { result = $0 }
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("expected delete to succeed")
        }
        // Gone from the UI, its worktree folder removed, and its branch deleted.
        XCTAssertFalse(model.controlListWorkspaces().contains { $0.id == info.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path))
        XCTAssertFalse(try Repository.open(atPath: repoPath).branchExists(info.branch))
    }

    func testDeleteWorkspaceRefusesPrimary() throws {
        let (model, primaryID, _) = try seededGitModel(primaryBranch: "main")
        var result: Result<Void, AppModel.WorkspaceDeleteError>?
        model.controlDeleteWorkspace(id: primaryID) { result = $0 }
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("expected failure for a primary workspace")
        }
        XCTAssertTrue(error.message.contains("primary"), "got: \(error.message)")
        XCTAssertTrue(model.controlListWorkspaces().contains { $0.id == primaryID.uuidString })
    }

    func testSetAgentState() {
        let (model, id) = seededModel()
        XCTAssertTrue(model.controlSetAgentState(.blocked, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
    }

    func testSetAgentStateDoneRaisesNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // not focused, so the bubble should arm
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        XCTAssertTrue(model.controlSetAgentState(.done, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .done)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "Done")
    }

    func testSetAgentStateDoneThenWorkingClearsCaptionAndLED() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // not focused, so the bubble arms
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        XCTAssertTrue(model.controlSetAgentState(.done, for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "Done")
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        // Resuming clears the stale "Done" notification entirely — caption and LED.
        XCTAssertTrue(model.controlSetAgentState(.working, for: id))
        XCTAssertNil(model.workspace(id: id)?.pendingNotificationMessage)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testDetectedDoneThenWorkingClearsCaptionAndLED() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // not focused, so the bubble arms
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        model.setDetectedAgentState(.done, for: id)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "Done")
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        // Resuming clears the stale "Done" notification entirely — caption and LED.
        model.setDetectedAgentState(.working, for: id)
        XCTAssertNil(model.workspace(id: id)?.pendingNotificationMessage)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testSetAgentStateBlockedDoesNotRaiseNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        XCTAssertTrue(model.controlSetAgentState(.blocked, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testSetAgentStateErrorDoesNotRaiseNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        XCTAssertTrue(model.controlSetAgentState(.error, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .error)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
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

    func testSelectingDoneWorkspaceCollapsesToIdle() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()  // a different workspace is selected first
        model.isWindowKey = { false }
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        _ = model.controlSetAgentState(.done, for: id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .done)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .idle)
    }

    func testSelectingDoneWorkspaceWhileUnfocusedCollapsesStateButLeavesBubbleArmed() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()  // a different workspace is selected first
        model.isWindowKey = { false }       // app backgrounded throughout
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        _ = model.controlSetAgentState(.done, for: id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .done)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)

        model.selectWorkspace(id)  // still backgrounded — selection alone is "seen", not "focused"
        // The state collapses (selection is enough to mean "seen")...
        XCTAssertEqual(model.workspace(id: id)?.agentState, .idle)
        // ...but the bubble stays armed until the window is actually key — the
        // deliberate "seen" (selection) vs "focused" (selection + key window) split.
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
    }

    func testSelectingBlockedWorkspaceLeavesStateUnchanged() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()
        model.isWindowKey = { false }
        _ = model.controlSetAgentState(.blocked, for: id)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
    }

    func testSelectingErrorWorkspaceLeavesStateUnchanged() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()
        model.isWindowKey = { false }
        _ = model.controlSetAgentState(.error, for: id)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .error)
    }

    func testRaiseNotificationStoresMessageWhenBubbleSet() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: id))
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "Done")
    }

    func testRaiseNotificationOnFocusedWorkspaceLeavesMessageNil() {
        let (model, id) = seededModel()   // id is the selected workspace
        model.isWindowKey = { true }      // and the window is key → focused
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: id))
        XCTAssertNil(model.workspace(id: id)?.pendingNotificationMessage)
    }

    func testRaiseNotificationOnFocusedWorkspaceDoesNotDeliver() {
        let (model, id) = seededModel()   // id is the selected workspace
        model.isWindowKey = { true }      // and the window is key → focused
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }
        XCTAssertTrue(model.controlRaiseNotification(message: "Done", for: id))
        XCTAssertEqual(delivered, 0, "no macOS notification is delivered while the workspace is focused")
    }

    func testRaiseNotificationWithNilMessageClearsPreviousMessage() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        _ = model.controlRaiseNotification(message: "first", for: id)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "first")
        _ = model.controlRaiseNotification(message: nil, for: id)  // bare re-notify
        XCTAssertNil(model.workspace(id: id)?.pendingNotificationMessage)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)  // bubble stays set
    }

    func testForegroundClearsMessageAlongsideBubble() {
        let (model, id) = seededModel()          // id is selected
        model.isWindowKey = { false }            // app backgrounded
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        _ = model.controlRaiseNotification(message: "Waiting for your input", for: id)
        model.isWindowKey = { true }             // app returns to foreground
        model.clearNotificationForFocusedWorkspace()
        XCTAssertNil(model.workspace(id: id)?.pendingNotificationMessage)
    }

    /// Captures the message (body) and interruption level a detected transition
    /// into `state` passes to `deliverNotification`. Returns nil when nothing is
    /// delivered. The workspace is left unfocused (window not key) so delivery is
    /// not suppressed by the focus check.
    private func deliveredNotification(
        forDetected state: AgentState) -> (body: String, level: UNNotificationInterruptionLevel)? {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // unfocused → delivery not suppressed
        var captured: (String, UNNotificationInterruptionLevel)?
        model.deliverNotification = { _, body, _, level in captured = (body, level) }
        model.setDetectedAgentState(state, for: id)
        return captured.map { (body: $0.0, level: $0.1) }
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

    func testDetectedIdleDeliversNothing() {
        XCTAssertNil(deliveredNotification(forDetected: .idle))
    }

    func testDetectedUnknownDeliversNothing() {
        XCTAssertNil(deliveredNotification(forDetected: .unknown))
    }

    func testDedupCooldownSuppressesSecondRapidNotification() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // unfocused → delivery not suppressed by focus
        var delivered = 0
        model.deliverNotification = { _, _, _, _ in delivered += 1 }
        // Two rapid calls for the same workspace within the cooldown window: the race
        // between an explicit `casper notify` and a near-simultaneous detection tick.
        _ = model.controlRaiseNotification(message: "Done", for: id)
        _ = model.controlRaiseNotification(message: "Done", for: id)
        XCTAssertEqual(delivered, 1, "the second notification within the cooldown is suppressed")
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

    private func modelWithWorktree(configJSON: String?) throws -> (AppModel, UUID) {
        let wt = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        if let configJSON {
            try configJSON.write(
                to: URL(fileURLWithPath: wt).appendingPathComponent(".casper.json"),
                atomically: true, encoding: .utf8)
        }
        let ws = Workspace(
            name: "main", worktreePath: wt, branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: wt))))
        let space = Space(name: "main", folderPath: wt, isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: SessionStore(fileURL: url), session: session), ws.id)
    }

    func testControlRunLaunchesNamedCommand() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"test":"npm test"}}}"#)
        guard case .success(let info) = model.controlRun(name: "test", in: wsID) else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(info.id.isEmpty)
    }

    func testControlRunDefaultsToRun() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"run":"npm run dev"}}}"#)
        guard case .success = model.controlRun(name: nil, in: wsID) else {
            return XCTFail("expected success for default 'run'")
        }
    }

    func testControlRunRejectsReservedName() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"setup":"npm i"}}}"#)
        guard case .failure(let error) = model.controlRun(name: "setup", in: wsID) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("reserved"), "message was: \(error.message)")
    }

    func testControlRunUnknownCommand() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"test":"npm test"}}}"#)
        guard case .failure(let error) = model.controlRun(name: "nope", in: wsID) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("nope"), "message was: \(error.message)")
    }

    func testControlRunNoConfig() throws {
        let (model, wsID) = try modelWithWorktree(configJSON: nil)
        guard case .failure(let error) = model.controlRun(name: "run", in: wsID) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains(".casper.json"), "message was: \(error.message)")
    }

    func testScriptCommandIsSubshellWrapped() {
        // A script that calls `exit` must not close the interactive terminal, so
        // the command runs in a subshell. The closing paren is on its own line so
        // a trailing `#` comment cannot swallow it.
        XCTAssertEqual(AppModel.subshellWrappedScriptCommand("exit 1"), "(\nexit 1\n)\n[ $? -eq 0 ] && exit")
        XCTAssertEqual(
            AppModel.subshellWrappedScriptCommand("npm test # smoke"),
            "(\nnpm test # smoke\n)\n[ $? -eq 0 ] && exit")
    }

    func testHookCommandExitsWithStatus() {
        // A lifecycle hook must let the shell exit with the command's status so
        // libghostty emits a child-exit event. `exit $?` sits on its own line so a
        // trailing `#` comment on the command's last line cannot swallow it.
        XCTAssertEqual(AppModel.hookWrappedScriptCommand("npm install"), "npm install\nexit $?")
        XCTAssertEqual(AppModel.hookWrappedScriptCommand("make # build"), "make # build\nexit $?")
    }

    func testNamedCommandsLoadedFromConfig() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"test":"npm test","run":"npm run dev","setup":"x"}}}"#)
        let names = model.namedCommands(for: wsID).map(\.name)
        XCTAssertEqual(names, ["run", "test"])  // sorted, reserved excluded
    }

    func testResolvedScriptPrefersRunThenAlphabetical() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"zeta":"z","run":"r"}}}"#)
        XCTAssertEqual(model.resolvedScript(for: try XCTUnwrap(model.workspace(id: wsID)))?.name, "run")

        let (model2, wsID2) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"zeta":"z","alpha":"a"}}}"#)
        XCTAssertEqual(model2.resolvedScript(for: try XCTUnwrap(model2.workspace(id: wsID2)))?.name, "alpha")
    }

    func testRunScriptRemembersLastUsed() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"test":"echo t","run":"echo r"}}}"#)
        model.runScript("test", for: wsID)
        XCTAssertEqual(model.workspace(id: wsID)?.lastUsedScript, "test")
        XCTAssertNil(model.scriptRunError)
        // Resolution now prefers the remembered command over the "run" default.
        XCTAssertEqual(model.resolvedScript(for: try XCTUnwrap(model.workspace(id: wsID)))?.name, "test")
    }

    func testRunScriptUnknownSetsError() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"run":"echo r"}}}"#)
        model.runScript("nope", for: wsID)
        XCTAssertNotNil(model.scriptRunError)
    }

    func testSelectScriptRemembersWithoutRunning() throws {
        let (model, wsID) = try modelWithWorktree(
            configJSON: #"{"workspace":{"scripts":{"test":"echo t","run":"echo r"}}}"#)
        model.selectScript("test", for: wsID)
        XCTAssertEqual(model.workspace(id: wsID)?.lastUsedScript, "test")
        XCTAssertNil(model.scriptRunError)
        // The remembered command becomes the resolved (primary-button) command.
        XCTAssertEqual(
            model.resolvedScript(for: try XCTUnwrap(model.workspace(id: wsID)))?.name, "test")
    }
}
