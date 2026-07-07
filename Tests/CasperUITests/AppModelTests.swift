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

    func testIsWorkspaceGitBackedReflectsOwningSpace() {
        let gitWorkspace = Workspace(name: "g", worktreePath: "/g", branch: "main",
                                     portBase: 40000,
                                     layout: .leaf(Surface(kind: .terminal(cwd: "/g", command: nil))))
        let plainWorkspace = Workspace(name: "p", worktreePath: "/p", branch: "",
                                       portBase: 40010,
                                       layout: .leaf(Surface(kind: .terminal(cwd: "/p", command: nil))))
        let existing = Session(spaces: [
            Space(name: "g", folderPath: "/g", isGitRepo: true, workspaces: [gitWorkspace]),
            Space(name: "p", folderPath: "/p", isGitRepo: false, workspaces: [plainWorkspace]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)

        XCTAssertTrue(model.isWorkspaceGitBacked(gitWorkspace))
        XCTAssertFalse(model.isWorkspaceGitBacked(plainWorkspace))
    }

    func testWorkspaceShortcutNumbersFollowSidebarOrderAndSkipCollapsedSpaces() {
        let spaceAPrimary = Workspace(name: "a-primary", worktreePath: "/a", branch: "main",
                                       portBase: 40000,
                                       layout: .leaf(Surface(kind: .terminal(cwd: "/a", command: nil))),
                                       kind: .primary)
        let spaceALinked = Workspace(name: "a-linked", worktreePath: "/a-linked", branch: "feature",
                                      portBase: 40010,
                                      layout: .leaf(Surface(kind: .terminal(cwd: "/a-linked", command: nil))),
                                      kind: .linked)
        let spaceA = Space(name: "a", folderPath: "/a", isGitRepo: true,
                            workspaces: [spaceALinked, spaceAPrimary])

        let hiddenOne = Workspace(name: "hidden-1", worktreePath: "/b1", branch: "",
                                   portBase: 40020,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b1", command: nil))))
        let hiddenTwo = Workspace(name: "hidden-2", worktreePath: "/b2", branch: "",
                                   portBase: 40030,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b2", command: nil))))
        let spaceB = Space(name: "b", folderPath: "/b", isGitRepo: false, isCollapsed: true,
                            workspaces: [hiddenOne, hiddenTwo])

        let spaceCWorkspace = Workspace(name: "c", worktreePath: "/c", branch: "",
                                         portBase: 40040,
                                         layout: .leaf(Surface(kind: .terminal(cwd: "/c", command: nil))))
        let spaceC = Space(name: "c", folderPath: "/c", isGitRepo: false, workspaces: [spaceCWorkspace])

        let session = Session(spaces: [spaceA, spaceB, spaceC])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)

        let numbers = model.workspaceShortcutNumbers
        XCTAssertEqual(numbers[spaceAPrimary.id], 1)
        XCTAssertEqual(numbers[spaceALinked.id], 2)
        XCTAssertNil(numbers[hiddenOne.id])
        XCTAssertNil(numbers[hiddenTwo.id])
        XCTAssertEqual(numbers[spaceCWorkspace.id], 3)
    }

    func testWorkspaceShortcutNumbersCapAtNine() {
        let workspaces = (1...11).map { index in
            Workspace(name: String(format: "w%02d", index), worktreePath: "/w\(index)", branch: "",
                      portBase: 40000 + index * 10,
                      layout: .leaf(Surface(kind: .terminal(cwd: "/w\(index)", command: nil))))
        }
        let space = Space(name: "many", folderPath: "/many", isGitRepo: false, workspaces: workspaces)
        let session = Session(spaces: [space])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)

        let numbers = model.workspaceShortcutNumbers
        XCTAssertEqual(numbers.count, 9)
        let ordered = space.orderedWorkspaces
        for (index, workspace) in ordered.enumerated() {
            if index < 9 {
                XCTAssertEqual(numbers[workspace.id], index + 1)
            } else {
                XCTAssertNil(numbers[workspace.id])
            }
        }
    }

    func testSelectWorkspaceAtShortcutNumberSelectsMatchingWorkspace() {
        let (model, _) = modelWithOnePlainWorkspace()
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/second"), probe: { _ in nil })
        let second = model.allWorkspaces.last!.id
        let numberForSecond = model.workspaceShortcutNumbers[second]!

        model.selectWorkspace(atShortcutNumber: numberForSecond)

        XCTAssertEqual(model.selectedWorkspaceID, second)
    }

    func testSelectWorkspaceAtShortcutNumberOutOfRangeIsNoOp() {
        let (model, workspaceID) = modelWithOnePlainWorkspace()
        model.selectedWorkspaceID = workspaceID

        model.selectWorkspace(atShortcutNumber: 7)

        XCTAssertEqual(model.selectedWorkspaceID, workspaceID)
    }

    func testShowWorkspaceShortcutHintsDefaultsFalse() {
        let (model, _) = modelWithOnePlainWorkspace()
        XCTAssertFalse(model.showWorkspaceShortcutHints)
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

    func testSelectWorkspaceUpdatesFocusedSurfaceToFirstSurfaceOfNewWorkspace() {
        let surface1 = Surface(kind: .terminal(cwd: "/a", command: nil))
        let surface2 = Surface(kind: .terminal(cwd: "/b", command: nil))
        let existing = Session(spaces: [
            Space(name: "s", folderPath: "/s", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .leaf(surface1)),
                Workspace(name: "b", worktreePath: "/b", branch: "",
                          portBase: 40010, layout: .leaf(surface2)),
            ]),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        // Restore selects the first workspace and focuses its surface.
        XCTAssertEqual(model.focusedSurfaceID, surface1.id)

        let workspace2 = existing.spaces[0].workspaces[1].id
        model.selectWorkspace(workspace2)
        XCTAssertEqual(model.selectedWorkspaceID, workspace2)
        XCTAssertEqual(model.focusedSurfaceID, surface2.id)
    }

    // MARK: - Persisted selection & Space expansion

    /// A two-workspace session in a single Space, plus the surfaces so tests can
    /// assert on focus. `selectedWorkspaceID` seeds the persisted selection.
    private func twoWorkspaceSession(
        isCollapsed: Bool = false, selecting selected: UUID? = nil
    ) -> (Session, Workspace, Surface, Workspace, Surface) {
        let surface1 = Surface(kind: .terminal(cwd: "/a", command: nil))
        let surface2 = Surface(kind: .terminal(cwd: "/b", command: nil))
        let ws1 = Workspace(name: "a", worktreePath: "/a", branch: "",
                            portBase: 40000, layout: .leaf(surface1))
        let ws2 = Workspace(name: "b", worktreePath: "/b", branch: "",
                            portBase: 40010, layout: .leaf(surface2))
        let session = Session(spaces: [
            Space(name: "s", folderPath: "/s", isGitRepo: false,
                  isCollapsed: isCollapsed, workspaces: [ws1, ws2]),
        ], selectedWorkspaceID: selected)
        return (session, ws1, surface1, ws2, surface2)
    }

    func testRestoresPersistedSelectedWorkspace() {
        let (session, _, _, ws2, surface2) = twoWorkspaceSession()
        let existing = Session(spaces: session.spaces, selectedWorkspaceID: ws2.id)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.selectedWorkspaceID, ws2.id)
        XCTAssertEqual(model.focusedSurfaceID, surface2.id)
    }

    func testRestoreFallsBackToFirstWhenSelectedWorkspaceMissing() {
        // A stale selection id (workspace since removed) must fall back to the
        // first workspace of the first Space, matching fresh-session behavior.
        let (session, ws1, surface1, _, _) = twoWorkspaceSession(selecting: UUID())
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)
        XCTAssertEqual(model.selectedWorkspaceID, ws1.id)
        XCTAssertEqual(model.focusedSurfaceID, surface1.id)
    }

    func testStartupExpandsSpaceOwningRestoredSelection() {
        let (session, _, _, ws2, _) = twoWorkspaceSession(isCollapsed: true)
        let existing = Session(spaces: session.spaces, selectedWorkspaceID: ws2.id)
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertFalse(model.spaces[0].isCollapsed)
    }

    func testSelectingWorkspaceExpandsItsCollapsedSpace() {
        let (model, _) = modelWithOnePlainWorkspace()
        let space = model.spaces[0]
        let wsID = space.workspaces[0].id
        model.toggleSpaceCollapsed(id: space.id)
        XCTAssertTrue(model.spaces[0].isCollapsed)

        model.selectWorkspace(wsID)
        XCTAssertFalse(model.spaces[0].isCollapsed)
    }

    func testSelectWorkspacePersistsSelectionAcrossReload() throws {
        let (session, _, _, ws2, _) = twoWorkspaceSession()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)
        model.selectWorkspace(ws2.id)
        XCTAssertEqual(try store.load().selectedWorkspaceID, ws2.id)
    }

    /// The selection invariant: it must be nil or resolve to a live workspace,
    /// never dangle at a removed id.
    private func assertSelectionValidOrNil(_ model: AppModel) {
        if let sel = model.selectedWorkspaceID {
            XCTAssertNotNil(model.workspace(id: sel), "selection dangles at a removed workspace")
        }
    }

    func testRemovingSelectedSpaceLeavingNoneClearsSelection() throws {
        let (session, _, _, _, _) = twoWorkspaceSession()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)
        model.removeSpace(id: model.spaces[0].id)  // the only Space holds the selection
        XCTAssertNil(model.selectedWorkspaceID)
        XCTAssertNil(try store.load().selectedWorkspaceID)
        assertSelectionValidOrNil(model)
    }

    func testRemovingSelectedLinkedWorkspaceReselectsValidWorkspace() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        _ = model.addLinkedWorkspace(spaceID: model.spaces[0].id, name: "feat")
        let linkedID = model.spaces[0].workspaces[1].id
        model.selectWorkspace(linkedID)

        model.removeWorkspace(id: linkedID)  // removing the selected linked workspace
        XCTAssertEqual(model.selectedWorkspaceID, model.spaces[0].workspaces[0].id)
        assertSelectionValidOrNil(model)
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
        let expectedWorktree = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-my-feature").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: expectedWorktree) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedWorktree))
    }

    func testAddLinkedWorkspaceAvoidsExistingDirectory() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let spaceID = model.spaces[0].id

        // Occupy the would-be target sibling so creation must fall back to `-2`.
        let taken = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-my-feature").path
        try FileManager.default.createDirectory(atPath: taken, withIntermediateDirectories: true)
        let suffixed = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-my-feature-2").path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: taken)
            try? FileManager.default.removeItem(atPath: suffixed)
        }

        XCTAssertTrue(model.addLinkedWorkspace(spaceID: spaceID, name: "My Feature"))
        let linked = model.spaces[0].workspaces[1]
        XCTAssertTrue(linked.worktreePath.hasSuffix("-my-feature-2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.worktreePath))
        XCTAssertEqual(linked.branch, "my-feature")
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

    // MARK: - Promotion on worktree change (degenerate space gaining .git)

    func testSelectingDegenerateSpaceThatGainedGitPromotesIt() {
        let dir = makeTempDir()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        XCTAssertFalse(model.spaces[0].isGitRepo)

        // Simulate `git init` by having the reprobe report a repo now.
        model.gitReprobe = { _ in
            WorkspaceFactory.GitInfo(canonicalPath: dir.path, branch: "main", remoteURL: nil)
        }
        // Selecting the space re-arms the watcher, which promotes on the way in.
        model.selectWorkspace(model.spaces[0].workspaces[0].id)
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "main")
    }

    func testWorktreeChangePromotesDegenerateSpaceAndBumpsRevision() {
        let dir = makeTempDir()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        // Capture the watcher's onChange so the test can fire a synthetic change.
        var captured: (@Sendable () -> Void)?
        model.makeWorktreeWatcher = { _, _, onChange in
            captured = onChange
            return StubDirectoryWatcher()
        }
        model.gitReprobe = { _ in nil }  // no repo yet: no promotion when the watcher arms
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        XCTAssertFalse(model.spaces[0].isGitRepo)
        let revisionBefore = model.diffRevision

        // Simulate `git init` landing, then a filesystem change firing.
        model.gitReprobe = { _ in
            WorkspaceFactory.GitInfo(canonicalPath: dir.path, branch: "main", remoteURL: nil)
        }
        captured?()

        // The bump is debounced (~0.2s), so wait a little before asserting.
        expectAfter(0.5)
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "main")
        XCTAssertGreaterThan(model.diffRevision, revisionBefore)
    }

    func testWorktreeChangeBumpsDiffRevisionForGitSpace() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        var captured: (@Sendable () -> Void)?
        model.makeWorktreeWatcher = { _, _, onChange in
            captured = onChange
            return StubDirectoryWatcher()
        }
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        XCTAssertTrue(model.spaces[0].isGitRepo)
        let revisionBefore = model.diffRevision

        captured?()

        // The bump is debounced (~0.2s), so wait a little before asserting.
        expectAfter(0.5)
        XCTAssertGreaterThan(model.diffRevision, revisionBefore)
    }

    // MARK: - Demotion on worktree change (Git space losing .git)

    func testWorktreeChangeDemotesSpaceWhenGitRemoved() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        var captured: (@Sendable () -> Void)?
        model.makeWorktreeWatcher = { _, _, onChange in
            captured = onChange
            return StubDirectoryWatcher()
        }
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)  // selects & arms the watcher
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertFalse(model.spaces[0].workspaces[0].branch.isEmpty)
        let revisionBefore = model.diffRevision

        // Simulate the `.git` directory being deleted, then a filesystem change firing.
        model.gitReprobe = { _ in nil }
        captured?()

        // The reaction is debounced (~0.2s), so wait a little before asserting.
        expectAfter(0.5)
        XCTAssertFalse(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "")
        XCTAssertGreaterThan(model.diffRevision, revisionBefore)
    }

    func testSelectionDoesNotDemoteOnTransientProbeFailure() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        XCTAssertTrue(model.spaces[0].isGitRepo)

        // A transient probe failure at selection/launch time must NOT demote:
        // demotion happens only on a live filesystem event, never on a probe.
        model.gitReprobe = { _ in nil }
        model.selectWorkspace(model.spaces[0].workspaces[0].id)
        XCTAssertTrue(model.spaces[0].isGitRepo)
    }

    func testLaunchPromotesAllDegenerateSpacesThatGainedGit() {
        let dir = makeTempDir()
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })  // starts degenerate
        XCTAssertFalse(model.spaces[0].isGitRepo)

        // `init`'s promote-all loop uses the default disk-hitting probe, but this
        // model is built via `addSpace` after construction and `gitReprobe` is
        // injected only afterwards — so exercise the same promote-only path
        // directly to assert a degenerate Space that gained a `.git` gets promoted.
        model.gitReprobe = { _ in
            WorkspaceFactory.GitInfo(canonicalPath: dir.path, branch: "main", remoteURL: nil)
        }
        XCTAssertTrue(model.promoteSpaceIfGitInitialized(spaceIndex: 0))
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "main")
    }

    /// Spin the main runloop for `seconds` so debounced main-queue work can run.
    private func expectAfter(_ seconds: TimeInterval) {
        let done = expectation(description: "waited \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
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
        let (model, _) = try modelWithOneGitWorkspace()
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

    func testSetBrowserURLPersists() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        // Browsers live only in the inspector now, so an address-bar navigation
        // (setBrowserURL) targets the workspace's inspector browser surface.
        let browserID = model.spaces[0].workspaces[0].inspector.browser.id
        model.setBrowserURL(browserID, URL(string: "http://localhost:3000")!)
        guard case .browser(let url) = model.spaces[0].workspaces[0].inspector.browser.kind else {
            return XCTFail("inspector browser surface is not a browser kind")
        }
        XCTAssertEqual(url.absoluteString, "http://localhost:3000")
    }

    // MARK: - Right inspector panel

    func testSetInspectorTabSelectsTabExpandsAndPersists() {
        let (model, _) = modelWithOnePlainWorkspace()
        let wsID = model.spaces[0].workspaces[0].id
        var saves = 0
        model.onPersistForTest = { saves += 1 }
        model.setInspectorTab(.browser, for: wsID)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.tab, .browser)
        XCTAssertFalse(model.spaces[0].workspaces[0].inspector.collapsed)
        XCTAssertEqual(saves, 1)
    }

    func testToggleInspectorCollapsedFlipsAndPersists() {
        let (model, _) = modelWithOnePlainWorkspace()
        let wsID = model.spaces[0].workspaces[0].id
        let before = model.spaces[0].workspaces[0].inspector.collapsed
        var saves = 0
        model.onPersistForTest = { saves += 1 }
        model.toggleInspectorCollapsed(for: wsID)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.collapsed, !before)
        XCTAssertEqual(saves, 1)
    }

    func testSetInspectorCollapsedSetsAndPersists() {
        let (model, _) = modelWithOnePlainWorkspace()
        let wsID = model.spaces[0].workspaces[0].id
        var saves = 0
        model.onPersistForTest = { saves += 1 }
        model.setInspectorCollapsed(false, for: wsID)
        XCTAssertFalse(model.spaces[0].workspaces[0].inspector.collapsed)
        model.setInspectorCollapsed(true, for: wsID)
        XCTAssertTrue(model.spaces[0].workspaces[0].inspector.collapsed)
        XCTAssertEqual(saves, 2)
    }

    func testSetInspectorWidthClampsAndPersistsPerWorkspace() {
        let (model, _) = modelWithOnePlainWorkspace()
        let wsID = model.spaces[0].workspaces[0].id

        model.setInspectorWidth(500, for: wsID)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.width, 500)

        model.setInspectorWidth(10_000, for: wsID)  // above max → clamped
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.width, InspectorState.maxWidth)

        model.setInspectorWidth(10, for: wsID)  // below min → clamped
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.width, InspectorState.minWidth)
    }

    func testSetBrowserURLWritesBackToInspectorBrowserWhenNotInLayout() {
        let (model, _) = modelWithOnePlainWorkspace()
        let inspectorBrowserID = model.spaces[0].workspaces[0].inspector.browser.id
        let layoutBefore = model.spaces[0].workspaces[0].layout
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        let url = URL(string: "http://localhost:8080")!
        model.setBrowserURL(inspectorBrowserID, url)  // id lives outside the layout tree

        guard case .browser(let newURL) =
            model.spaces[0].workspaces[0].inspector.browser.kind else {
            return XCTFail("inspector browser must stay a browser surface")
        }
        XCTAssertEqual(newURL, url)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.browser.id, inspectorBrowserID)
        // The layout tree is untouched: the write-back hit the inspector browser only.
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
        // setBrowserURL persists via the debounced scheduleSave(); flush it so the
        // save fires synchronously instead of after the 0.5s debounce delay.
        model.flushPendingSave()
        XCTAssertEqual(saves, 1)
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
    private func surfaceKindIsTerminal(_ node: LayoutNode, _ id: UUID) -> Bool {
        if case .terminal = surface(node, id)?.kind { return true }
        return false
    }
}

/// Trivial `DirectoryWatching` stub: lets AppModel watcher-wiring tests capture
/// the `onChange` callback without spinning up a real FSEvents stream.
private final class StubDirectoryWatcher: DirectoryWatching {
    func stop() {}
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
