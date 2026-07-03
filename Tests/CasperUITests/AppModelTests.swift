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
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
            ]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, existing.spaces[0].workspaces[0].id)
    }

    func testAddAfterRestoreDoesNotReuseRestoredPortBlock() {
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
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
