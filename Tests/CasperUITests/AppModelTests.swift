import Clibgit2
import XCTest
import CasperAgents
import CasperCore
@testable import CasperGit
@testable import CasperUI

@MainActor
final class AppModelTests: XCTestCase {
    private func makeStore() -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return (SessionStore(fileURL: url), url)
    }

    /// The id of the Space that contains the workspace with the given id.
    private func containingSpaceID(_ model: AppModel, workspace id: UUID) -> UUID {
        model.spaces.first(where: { $0.workspaces.contains(where: { $0.id == id }) })!.id
    }

    func testStartsEmptyWhenSessionEmpty() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.selectedWorkspaceID)
    }

    func testAddWorkspaceAppendsSelectsAndPersists() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/plain"), probe: { _ in nil })
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.allWorkspaces[0].id)
        // Persisted synchronously.
        XCTAssertEqual(try store.load().spaces.flatMap(\.workspaces).count, 1)
    }

    func testAddedWorkspacesGetDistinctPortBlocks() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertNotEqual(model.allWorkspaces[0].portBase, model.allWorkspaces[1].portBase)
    }

    func testRemoveDeletesEntryAndFixesSelection() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let second = model.allWorkspaces[1].id
        model.selectedWorkspaceID = second
        model.removeSpace(id: containingSpaceID(model, workspace: second))
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.allWorkspaces[0].id)
        XCTAssertEqual(try store.load().spaces.flatMap(\.workspaces).count, 1)
    }

    func testRestoresPersistedSessionAndSelectsFirst() {
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a", command: nil)))),
            ]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, existing.spaces[0].workspaces[0].id)
    }

    func testFreshModelSeedsFocusedSurfaceIDToFirstSurfaceOfSelectedWorkspace() {
        let surface = Surface(kind: .terminal(cwd: "/a", command: nil))
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .leaf(surface)),
            ]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.focusedSurfaceID, surface.id)
    }

    func testAddAfterRestoreDoesNotReuseRestoredPortBlock() {
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a", command: nil)))),
            ]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertEqual(model.allWorkspaces.count, 2)
        XCTAssertNotEqual(model.allWorkspaces[1].portBase, 40000)
    }

    private func todoWritePayload() -> Data {
        let json: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "TodoWrite",
            "tool_input": ["todos": [["content": "task", "status": "in_progress"]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testHookMessageUpdatesAddressedWorkspace() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.allWorkspaces[0].id
        let msg = HookMessage(workspaceId: id, hookPayload: todoWritePayload())
        model.handleHookMessage(msg, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .running)
        XCTAssertEqual(model.allWorkspaces[0].todos.first?.content, "task")
    }

    func testUnfocusedNotificationEventDeliversNotification() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        var delivered: [(String, String)] = []
        model.deliverNotification = { title, body in delivered.append((title, body)) }
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.allWorkspaces[0].id
        let payload = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "message": "needs input",
        ])
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: payload),
                                now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .waiting)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.1, "needs input")
    }

    func testUnknownWorkspaceMessageIsIgnored() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let before = model.allWorkspaces[0]
        let msg = HookMessage(workspaceId: UUID(), hookPayload: todoWritePayload())
        model.handleHookMessage(msg, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.allWorkspaces[0], before)
    }

    func testHeartbeatMarksSilentWorkspaceUnknown() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.allWorkspaces[0].id
        // Activity at t=1000 puts it in running.
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: todoWritePayload()),
                                now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .running)
        // 31s later it is stale.
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1031))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .unknown)
    }

    func testHeartbeatLeavesFreshWorkspaceUntouched() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.allWorkspaces[0].id
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: todoWritePayload()),
                                now: Date(timeIntervalSince1970: 1000))
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .running)
    }

    func testHeartbeatIgnoresWorkspaceWithNoActivity() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 9999))
        XCTAssertEqual(model.allWorkspaces[0].agentState, .idle)
    }

    func testHeartbeatAfterRemoveLeavesRemainingWorkspacesUnchanged() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let removedID = model.allWorkspaces[0].id
        let remainingID = model.allWorkspaces[1].id
        model.handleHookMessage(
            HookMessage(workspaceId: removedID, hookPayload: todoWritePayload()),
            now: Date(timeIntervalSince1970: 1000))
        model.handleHookMessage(
            HookMessage(workspaceId: remainingID, hookPayload: todoWritePayload()),
            now: Date(timeIntervalSince1970: 1000))
        model.removeSpace(id: containingSpaceID(model, workspace: removedID))
        // The stale activity entry for the removed workspace must not resurface
        // on a later tick and must not crash despite the workspace being gone.
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.allWorkspaces[0].agentState, .running)
    }

    func testSessionRoundTripsThroughRealSessionStore() throws {
        let (store, url) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/roundtrip"), probe: { _ in nil })

        let reloadedStore = SessionStore(fileURL: url)
        let reloadedSession = try reloadedStore.load()
        let reloadedModel = AppModel(sessionStore: reloadedStore, session: reloadedSession)

        XCTAssertEqual(reloadedModel.allWorkspaces.count, 1)
        XCTAssertEqual(reloadedModel.allWorkspaces[0].name, model.allWorkspaces[0].name)
        XCTAssertEqual(reloadedModel.allWorkspaces[0].portBase, model.allWorkspaces[0].portBase)
    }

    // MARK: - gitProbe (disk-backed)

    /// Regression test for `gitProbe` using `Repository.open` (exact-path,
    /// no parent-directory walk) rather than `Repository.discover`. Builds a
    /// real repo on disk, mirroring the fixture in `WorktreeManagerTests`.
    func testGitProbeOpensExactFolderAndDoesNotWalkUpFromASubdirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-gitprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try seedRepository(at: root.path)

        let probed = AppModel.gitProbe(root)
        XCTAssertEqual(probed?.canonicalPath, root.standardizedFileURL.path)
        XCTAssertNotEqual(probed?.branch, "")

        let subdir = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        // Repository.open is an exact-path open: probing a subdirectory of the
        // repo must not find the ancestor repository rooted at `root`.
        XCTAssertNil(AppModel.gitProbe(subdir))
    }

    /// Seed a repo with one commit via CasperGit (mirrors `WorktreeManagerTests`).
    private func seedRepository(at path: String) throws {
        let repo = try Repository.initialize(atPath: path)
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "seed\n".write(to: readme, atomically: true, encoding: .utf8)
        try makeInitialCommit(repo: repo, path: path)
    }

    /// A fresh temp directory on disk, removed after the test.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A temp directory seeded as a real Git repo with one initial commit on
    /// the default branch, via `seedRepository`.
    private func makeTempGitRepo() throws -> URL {
        let dir = makeTempDir()
        try seedRepository(at: dir.path)
        return dir
    }

    // MARK: - Linked workspaces (Task 5)

    func testAddLinkedWorkspaceCreatesWorktreeAndPort() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let spaceID = model.spaces[0].id
        let primaryPort = model.spaces[0].workspaces[0].portBase

        XCTAssertTrue(model.addLinkedWorkspace(spaceID: spaceID, name: "My Feature"))
        let linked = model.spaces[0].workspaces[1]
        XCTAssertEqual(linked.kind, .linked)
        XCTAssertEqual(linked.branch, "my-feature")
        XCTAssertEqual(linked.baseBranch, model.spaces[0].workspaces[0].branch)
        XCTAssertNotEqual(linked.portBase, primaryPort)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            repo.appendingPathComponent(".casper/worktrees/my-feature").path))
        let exclude = try String(contentsOf:
            repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertTrue(exclude.contains(".casper/"))
    }

    func testAddLinkedWorkspaceRejectedForNonGitSpace() {
        let dir = makeTempDir()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        XCTAssertFalse(model.addLinkedWorkspace(spaceID: model.spaces[0].id, name: "x"))
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
    }

    func testRemoveWorkspaceLinkedOnlyReleasesPort() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let spaceID = model.spaces[0].id
        _ = model.addLinkedWorkspace(spaceID: spaceID, name: "feat")
        let linkedID = model.spaces[0].workspaces[1].id

        model.removeWorkspace(id: linkedID)  // linked → dropped
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)

        let primaryID = model.spaces[0].workspaces[0].id
        model.removeWorkspace(id: primaryID)  // primary → refused
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
    }

    func testAddSpaceRejectsDuplicateFolder() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        XCTAssertEqual(model.spaces.count, 1)
    }

    func testAddSpaceRejectsDuplicateFolderThroughSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realRepo = root.appendingPathComponent("realrepo")
        try FileManager.default.createDirectory(at: realRepo, withIntermediateDirectories: true)
        try seedRepository(at: realRepo.path)
        let link = root.appendingPathComponent("linkrepo")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: realRepo.path)

        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: realRepo, probe: AppModel.gitProbe)
        model.addSpace(folderURL: link, probe: AppModel.gitProbe)
        XCTAssertEqual(model.spaces.count, 1)
    }

    // MARK: - Promotion on heartbeat (Task 6)

    func testDegenerateSpaceIsPromotedOnHeartbeat() {
        let dir = makeTempDir()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        XCTAssertFalse(model.spaces[0].isGitRepo)

        // Simulate `git init` by having the reprobe report a repo now.
        model.gitReprobe = { _ in
            WorkspaceFactory.GitInfo(canonicalPath: dir.path, branch: "main", remoteURL: nil)
        }
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "main")
        XCTAssertEqual(saves, 1)

        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1_000_001))  // no further change
        XCTAssertEqual(saves, 1)
    }

    // MARK: - Focus and layout mutations (Task 3)

    private func modelWithOneGitWorkspace() throws -> (AppModel, UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-ui3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try seedRepository(at: root.path)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: root, probe: AppModel.gitProbe)
        let surfaceID = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0]
        model.focusSurface(surfaceID)
        return (model, surfaceID)
    }

    func testApplyNewSplitGrowsTheTree() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applyNewSplit(.right)
        let layout = model.spaces[0].workspaces[0].layout
        guard case .split(let o, let children, _) = layout else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertNotEqual(model.focusedSurfaceID, first)  // focus moved to the new surface
        XCTAssertEqual(LayoutTree.surfaceIDs(layout).count, 2)
    }

    func testApplyNewTerminalSplitsInAndMovesFocus() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applyNewTerminal()
        let layout = model.spaces[0].workspaces[0].layout
        // The single leaf becomes a horizontal split of two terminal leaves.
        guard case .split(let orientation, let children, _) = layout else { return XCTFail() }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(LayoutTree.surfaceIDs(layout).count, 2)
        // Focus moves to the freshly created terminal.
        let focus = model.focusedSurfaceID!
        XCTAssertNotEqual(focus, first)
        XCTAssertTrue(surfaceKindIsTerminal(layout, focus))
    }

    func testCloseLastSurfaceOfPrimaryRemovesSpace() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applyCloseFocusedSurface()  // only surface -> closes the workspace
        XCTAssertTrue(model.spaces.isEmpty)  // primary -> whole Space removed
    }

    func testCloseOneOfTwoSurvives() throws {
        let (model, _) = try modelWithOneGitWorkspace()
        model.applyNewSplit(.right)  // now two surfaces, focus on the new one
        model.applyCloseFocusedSurface()
        XCTAssertEqual(
            LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 1)
        XCTAssertEqual(model.spaces.count, 1)
    }

    func testCloseBackgroundSurfaceLeavesFocusUntouched() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applyNewSplit(.right)  // two surfaces; focus moves to the new one
        let background = model.focusedSurfaceID!
        model.focusSurface(first)  // focus the original surface again

        model.applyCloseSurface(background)  // close the non-focused surface

        XCTAssertEqual(model.focusedSurfaceID, first)  // focus must not migrate
        XCTAssertEqual(
            LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 1)
    }

    func testApplySplitFromSurfaceSplitsInGivenDirection() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applySplit(from: first, direction: .down)  // context-menu split; always a terminal
        let layout = model.spaces[0].workspaces[0].layout
        guard case .split(let orientation, let children, _) = layout else { return XCTFail() }
        XCTAssertEqual(orientation, .vertical)  // a downward split stacks vertically
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(LayoutTree.surfaceIDs(layout).count, 2)
        let focus = model.focusedSurfaceID!
        XCTAssertNotEqual(focus, first)  // focus moves to the new terminal
        XCTAssertTrue(surfaceKindIsTerminal(layout, focus))
    }

    // MARK: - Browser surfaces (UI-4 Task 1)

    private func modelWithOnePlainWorkspace() -> (AppModel, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-ui4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })
        let sid = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0]
        model.focusSurface(sid)
        return (model, sid)
    }

    func testApplyNewBrowserAddsBrowserSurface() {
        let (model, _) = modelWithOnePlainWorkspace()
        model.applyNewBrowser()
        let ids = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)
        XCTAssertEqual(ids.count, 2)
        let created = model.spaces[0].workspaces[0].layout
        // The new focused surface is a browser.
        let focus = model.focusedSurfaceID!
        XCTAssertTrue(surfaceKindIsBrowser(created, focus))
    }

    func testApplyNewBrowserWithAnchorSplitsBesideAnchorNotFocus() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.applyNewSplit(.right)  // two surfaces; focus is on the new (second) one
        let second = model.focusedSurfaceID!

        model.focusSurface(first)  // point global focus back at the FIRST surface
        model.applyNewBrowser(anchor: second)  // anchor overrides focus

        // The browser splits in beside the anchored surface, so it lands
        // immediately after `second` — not after the focused `first`.
        let ids = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)
        let browser = model.focusedSurfaceID!
        XCTAssertEqual(ids, [first, second, browser])
        XCTAssertTrue(surfaceKindIsBrowser(model.spaces[0].workspaces[0].layout, browser))
    }

    func testSetBrowserURLPersists() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        model.applyNewBrowser()
        let focus = model.focusedSurfaceID!
        model.setBrowserURL(focus, URL(string: "http://localhost:3000")!)
        XCTAssertTrue(browserURL(model.spaces[0].workspaces[0].layout, focus)?.absoluteString
            == "http://localhost:3000")
    }

    // MARK: - Diff surfaces (UI-5 Task 1)

    func testComputeDiffReturnsChangesForDirtyWorktree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-ui5diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedRepository(at: dir.path)  // existing helper: repo + one commit (README.md)
        try "changed\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let ws = model.spaces[0].workspaces[0]
        let diff = model.computeDiff(for: ws)
        XCTAssertNotNil(diff)
        XCTAssertFalse(diff!.files.isEmpty)
    }

    func testComputeDiffNilForNonGitWorkspace() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-ui5nogit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })
        XCTAssertNil(model.computeDiff(for: model.spaces[0].workspaces[0]))
    }

    func testDiffSummaryCountsChangedLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-ui5summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedRepository(at: dir.path)  // repo + one commit (README.md == "seed\n")
        try "seed\nadded\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let summary = model.diffSummary(for: model.spaces[0].workspaces[0])
        XCTAssertEqual(summary?.insertions, 1)
        XCTAssertEqual(summary?.deletions, 0)
    }

    // Helpers: walk the layout to find a surface by id and inspect its kind.
    private func surface(_ node: LayoutNode, _ id: UUID) -> Surface? {
        switch node {
        case .leaf(let s):
            return s.id == id ? s : nil
        case .split(_, let children, _):
            for c in children { if let found = surface(c, id) { return found } }
            return nil
        }
    }
    private func surfaceKindIsBrowser(_ node: LayoutNode, _ id: UUID) -> Bool {
        browserURL(node, id) != nil
    }
    private func surfaceKindIsTerminal(_ node: LayoutNode, _ id: UUID) -> Bool {
        if case .terminal = surface(node, id)?.kind { return true }
        return false
    }
    private func browserURL(_ node: LayoutNode, _ id: UUID) -> URL? {
        if case .browser(let url) = surface(node, id)?.kind { return url }
        return nil
    }
}

/// Throw a plain `NSError` when a libgit2 call returns a negative code. `gitCheck`
/// itself is `internal` to `CasperGit`; this local equivalent keeps the commit
/// helper below a literal copy of `WorktreeManagerTests`'s libgit2 sequence
/// without pulling `GitError` construction into a test file.
private func check(_ code: Int32) throws {
    if code < 0 {
        throw NSError(domain: "git", code: Int(code))
    }
}

/// Create one commit on `repo`'s working tree at `path`, using the same
/// libgit2 sequence as `WorktreeManagerTests`: stage the README already
/// written by the caller, build a tree from the index, and commit it onto
/// HEAD. `repo` must already be open on an initialized, unborn repository —
/// this helper does not call `Repository.initialize`.
private func makeInitialCommit(repo: Repository, path: String) throws {
    var index: OpaquePointer?
    try check(git_repository_index(&index, repo.pointer))
    defer { git_index_free(index) }
    try check(git_index_add_bypath(index, "README.md"))
    try check(git_index_write(index))

    var treeOid = git_oid()
    try check(git_index_write_tree(&treeOid, index))
    var tree: OpaquePointer?
    try check(git_tree_lookup(&tree, repo.pointer, &treeOid))
    defer { git_tree_free(tree) }

    var signature: UnsafeMutablePointer<git_signature>?
    try check(git_signature_now(&signature, "Casper Test", "test@casper.local"))
    defer { git_signature_free(signature) }

    // Swift cannot import the variadic `git_commit_create_v`, so use the
    // array-based `git_commit_create` with zero parents (initial commit).
    var commitOid = git_oid()
    try check(git_commit_create(
        &commitOid, repo.pointer, "HEAD",
        signature, signature, nil, "Initial commit", tree, 0, nil))
}
