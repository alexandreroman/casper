import Clibgit2
import XCTest
import CasperAgents
import CasperCore
@testable import CasperGhostty
@testable import CasperGit
@testable import CasperUI

@MainActor
final class AppModelTests: XCTestCase {
    /// The id of the Space that contains the workspace with the given id.
    private func containingSpaceID(_ model: AppModel, workspace id: UUID) -> UUID {
        model.spaces.first(where: { $0.workspaces.contains(where: { $0.id == id }) })!.id
    }

    func testStartsEmptyWhenSessionEmpty() {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertNil(model.selectedWorkspaceID)
    }

    func testAddWorkspaceAppendsSelectsAndPersists() throws {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/plain"), probe: { _ in nil })
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.allWorkspaces[0].id)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
        XCTAssertEqual(try store.load().spaces.flatMap(\.workspaces).count, 1)
    }

    func testAddedWorkspacesGetDistinctPortBlocks() {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertNotEqual(model.allWorkspaces[0].portBase, model.allWorkspaces[1].portBase)
    }

    func testAddSpaceInsertsAtAlphabeticalPosition() {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/zebra"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/alpha"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/mango"), probe: { _ in nil })
        XCTAssertEqual(model.spaces.map(\.name), ["alpha", "mango", "zebra"])
    }

    func testRemoveDeletesEntryAndFixesSelection() throws {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let second = model.allWorkspaces[1].id
        model.selectedWorkspaceID = second
        model.removeSpace(id: containingSpaceID(model, workspace: second))
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.allWorkspaces[0].id)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
        XCTAssertEqual(try store.load().spaces.flatMap(\.workspaces).count, 1)
    }

    func testRestoresPersistedSessionAndSelectsFirst() {
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
        XCTAssertEqual(model.allWorkspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, existing.spaces[0].workspaces[0].id)
    }

    func testRestoredSessionSortsSpacesAlphabetically() {
        let existing = Session(spaces: [
            Space(name: "zebra", folderPath: "/z", isGitRepo: false, workspaces: [
                Workspace(name: "zebra", worktreePath: "/z", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/z")))),
            ]),
            Space(name: "alpha", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "alpha", worktreePath: "/a", branch: "", portBase: 40010,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
            Space(name: "Mango", folderPath: "/m", isGitRepo: false, workspaces: [
                Workspace(name: "mango", worktreePath: "/m", branch: "", portBase: 40020,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/m")))),
            ]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
        XCTAssertEqual(model.spaces.map(\.name), ["alpha", "Mango", "zebra"])
    }

    func testIsWorkspaceGitBackedReflectsOwningSpace() {
        let gitWorkspace = Workspace(name: "g", worktreePath: "/g", branch: "main",
                                     portBase: 40000,
                                     layout: .leaf(Surface(kind: .terminal(cwd: "/g"))))
        let plainWorkspace = Workspace(name: "p", worktreePath: "/p", branch: "",
                                       portBase: 40010,
                                       layout: .leaf(Surface(kind: .terminal(cwd: "/p"))))
        let existing = Session(spaces: [
            Space(name: "g", folderPath: "/g", isGitRepo: true, workspaces: [gitWorkspace]),
            Space(name: "p", folderPath: "/p", isGitRepo: false, workspaces: [plainWorkspace]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)

        XCTAssertTrue(model.isWorkspaceGitBacked(gitWorkspace))
        XCTAssertFalse(model.isWorkspaceGitBacked(plainWorkspace))
    }

    func testWorkspaceShortcutNumbersFollowSidebarOrderAndSkipCollapsedSpaces() {
        let spaceAPrimary = Workspace(name: "a-primary", worktreePath: "/a", branch: "main",
                                       portBase: 40000,
                                       layout: .leaf(Surface(kind: .terminal(cwd: "/a"))),
                                       kind: .primary)
        let spaceALinked = Workspace(name: "a-linked", worktreePath: "/a-linked", branch: "feature",
                                      portBase: 40010,
                                      layout: .leaf(Surface(kind: .terminal(cwd: "/a-linked"))),
                                      kind: .linked)
        let spaceA = Space(name: "a", folderPath: "/a", isGitRepo: true,
                            workspaces: [spaceALinked, spaceAPrimary])

        let hiddenOne = Workspace(name: "hidden-1", worktreePath: "/b1", branch: "",
                                   portBase: 40020,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b1"))))
        let hiddenTwo = Workspace(name: "hidden-2", worktreePath: "/b2", branch: "",
                                   portBase: 40030,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b2"))))
        let spaceB = Space(name: "b", folderPath: "/b", isGitRepo: false, isCollapsed: true,
                            workspaces: [hiddenOne, hiddenTwo])

        let spaceCWorkspace = Workspace(name: "c", worktreePath: "/c", branch: "",
                                         portBase: 40040,
                                         layout: .leaf(Surface(kind: .terminal(cwd: "/c"))))
        let spaceC = Space(name: "c", folderPath: "/c", isGitRepo: false, workspaces: [spaceCWorkspace])

        let session = Session(spaces: [spaceA, spaceB, spaceC])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)

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
                      layout: .leaf(Surface(kind: .terminal(cwd: "/w\(index)"))))
        }
        let space = Space(name: "many", folderPath: "/many", isGitRepo: false, workspaces: workspaces)
        let session = Session(spaces: [space])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)

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
        let surface = Surface(kind: .terminal(cwd: "/a"))
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .leaf(surface)),
            ]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
        XCTAssertEqual(model.focusedSurfaceID, surface.id)
    }

    func testSelectWorkspaceUpdatesFocusedSurfaceToFirstSurfaceOfNewWorkspace() {
        let surface1 = Surface(kind: .terminal(cwd: "/a"))
        let surface2 = Surface(kind: .terminal(cwd: "/b"))
        let existing = Session(spaces: [
            Space(name: "s", folderPath: "/s", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "",
                          portBase: 40000, layout: .leaf(surface1)),
                Workspace(name: "b", worktreePath: "/b", branch: "",
                          portBase: 40010, layout: .leaf(surface2)),
            ]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
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
        let surface1 = Surface(kind: .terminal(cwd: "/a"))
        let surface2 = Surface(kind: .terminal(cwd: "/b"))
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
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
        XCTAssertEqual(model.selectedWorkspaceID, ws2.id)
        XCTAssertEqual(model.focusedSurfaceID, surface2.id)
    }

    func testRestoreFallsBackToFirstWhenSelectedWorkspaceMissing() {
        // A stale selection id (workspace since removed) must fall back to the
        // first workspace of the first Space, matching fresh-session behavior.
        let (session, ws1, surface1, _, _) = twoWorkspaceSession(selecting: UUID())
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)
        XCTAssertEqual(model.selectedWorkspaceID, ws1.id)
        XCTAssertEqual(model.focusedSurfaceID, surface1.id)
    }

    func testStartupExpandsSpaceOwningRestoredSelection() {
        let (session, _, _, ws2, _) = twoWorkspaceSession(isCollapsed: true)
        let existing = Session(spaces: session.spaces, selectedWorkspaceID: ws2.id)
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
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
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)
        model.selectWorkspace(ws2.id)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
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
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)
        model.removeSpace(id: model.spaces[0].id)  // the only Space holds the selection
        XCTAssertNil(model.selectedWorkspaceID)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
        XCTAssertNil(try store.load().selectedWorkspaceID)
        assertSelectionValidOrNil(model)
    }

    func testRemovingSelectedLinkedWorkspaceReselectsValidWorkspace() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        _ = await model.addLinkedWorkspace(spaceID: model.spaces[0].id, name: "feat")
        let linkedID = model.spaces[0].workspaces[1].id
        model.selectWorkspace(linkedID)

        model.removeWorkspace(id: linkedID)  // removing the selected linked workspace
        XCTAssertEqual(model.selectedWorkspaceID, model.spaces[0].workspaces[0].id)
        assertSelectionValidOrNil(model)
    }

    func testRemovingSelectedLinkedWorkspacePrefersSiblingInSameSpace() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let gitSpaceID = model.spaces[0].id
        _ = await model.addLinkedWorkspace(spaceID: gitSpaceID, name: "Feature One")
        _ = await model.addLinkedWorkspace(spaceID: gitSpaceID, name: "Feature Two")
        // Alphabetically before the repo's temp-dir name ("casper-test-…"), so
        // this Space becomes `spaces[0]` and the Git Space becomes `spaces[1]`.
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/aaa-first-space"), probe: { _ in nil })

        XCTAssertEqual(model.spaces[0].name, "aaa-first-space")
        let gitSpace = try XCTUnwrap(model.spaces.first(where: { $0.id == gitSpaceID }))
        let featureTwoID = try XCTUnwrap(
            gitSpace.workspaces.first(where: { $0.branch == "feature-two" })?.id)
        let gitSpacePrimaryID = gitSpace.workspaces[0].id

        model.selectWorkspace(featureTwoID)
        model.removeWorkspace(id: featureTwoID)

        // Must land on the remaining workspace in the SAME Space (its primary,
        // since "feature-one" and the primary both sort after "feature-two" is
        // gone, and primary sorts first in display order) — not jump to the
        // alphabetically-first Space overall ("aaa-first-space"'s primary).
        XCTAssertEqual(model.selectedWorkspaceID, gitSpacePrimaryID)
    }

    func testAddAfterRestoreDoesNotReuseRestoredPortBlock() {
        let existing = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: existing)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertEqual(model.allWorkspaces.count, 2)
        XCTAssertNotEqual(model.allWorkspaces[1].portBase, 40000)
    }

    func testSessionRoundTripsThroughRealSessionStore() throws {
        let (store, url) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/roundtrip"), probe: { _ in nil })

        // The disk write is backgrounded; flush so the reload below sees it.
        model.flushPendingSave()
        let reloadedStore = SessionStore(fileURL: url)
        let reloadedSession = try reloadedStore.load()
        let reloadedModel = makeModel(store: reloadedStore, session: reloadedSession)

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

    /// A temp directory seeded as a real Git repo with one initial commit on
    /// the default branch, via `seedRepository`.
    private func makeTempGitRepo() throws -> URL {
        let dir = makeTemporaryDirectory()
        try seedRepository(at: dir.path)
        return dir
    }

    // MARK: - Linked workspaces (Task 5)

    func testAddLinkedWorkspaceCreatesWorktreeAndPort() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let spaceID = model.spaces[0].id
        let primaryPort = model.spaces[0].workspaces[0].portBase

        let created = await model.addLinkedWorkspace(spaceID: spaceID, name: "My Feature")
        XCTAssertTrue(created)
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

    func testAddLinkedWorkspaceAvoidsExistingDirectory() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

        let created = await model.addLinkedWorkspace(spaceID: spaceID, name: "My Feature")
        XCTAssertTrue(created)
        let linked = model.spaces[0].workspaces[1]
        XCTAssertTrue(linked.worktreePath.hasSuffix("-my-feature-2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.worktreePath))
        XCTAssertEqual(linked.branch, "my-feature")
    }

    func testAddLinkedWorkspaceRejectedForNonGitSpace() async {
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let created = await model.addLinkedWorkspace(spaceID: model.spaces[0].id, name: "x")
        XCTAssertFalse(created)
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
    }

    func testRemoveWorkspaceLinkedOnlyReleasesPort() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let spaceID = model.spaces[0].id
        _ = await model.addLinkedWorkspace(spaceID: spaceID, name: "feat")
        let linkedID = model.spaces[0].workspaces[1].id

        model.removeWorkspace(id: linkedID)  // linked → dropped
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)

        let primaryID = model.spaces[0].workspaces[0].id
        model.removeWorkspace(id: primaryID)  // primary → refused
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
    }

    func testAddSpaceRejectsDuplicateFolder() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: realRepo, probe: AppModel.gitProbe)
        model.addSpace(folderURL: link, probe: AppModel.gitProbe)
        XCTAssertEqual(model.spaces.count, 1)
    }

    // MARK: - Adding a folder that is a worktree of an open repository

    /// A worktree of `repo` at a sibling path, registered under `name` on a branch
    /// of the same name. Returns its folder URL.
    private func makeWorktree(of repo: URL, named name: String) throws -> URL {
        let worktree = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-" + name)
        addTeardownBlock { try? FileManager.default.removeItem(at: worktree) }
        let handle = try Repository.open(atPath: repo.path)
        _ = try handle.addWorktree(name: name, atPath: worktree.path, basedOn: nil)
        return worktree
    }

    func testAddFolderAdoptsWorktreeIntoItsRepositorySpace() throws {
        let repo = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repo, named: "adopted")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        let primary = model.spaces[0].workspaces[0]

        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces.count, 1)  // no Space of its own
        XCTAssertEqual(model.spaces[0].workspaces.count, 2)
        let adopted = model.spaces[0].workspaces[1]
        XCTAssertEqual(adopted.kind, .linked)
        XCTAssertEqual(adopted.branch, "adopted")
        XCTAssertEqual(adopted.name, "adopted")
        XCTAssertEqual(adopted.baseBranch, primary.branch)
        XCTAssertNotEqual(adopted.portBase, primary.portBase)
        XCTAssertEqual(
            URL(fileURLWithPath: adopted.worktreePath).resolvingSymlinksInPath().path,
            worktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.selectedWorkspaceID, adopted.id)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
        XCTAssertEqual(try store.load().spaces.flatMap(\.workspaces).count, 2)
    }

    func testAddFolderAdoptsWorktreeIntoCollapsedSpaceAndExpandsIt() throws {
        let repo = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repo, named: "adopted")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        model.toggleSpaceCollapsed(id: model.spaces[0].id)
        XCTAssertTrue(model.spaces[0].isCollapsed)

        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)

        // Selecting the adopted workspace must reveal it.
        XCTAssertFalse(model.spaces[0].isCollapsed)
        XCTAssertEqual(model.spaces[0].workspaces.count, 2)
    }

    func testAddFolderKeepsWorktreeOfUnopenedRepositoryAsItsOwnSpace() throws {
        let repo = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repo, named: "solo")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)

        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces.count, 1)
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
        XCTAssertEqual(model.spaces[0].workspaces[0].kind, .primary)
    }

    func testAddFolderIgnoresRepositoryOpenedInADifferentSession() throws {
        let repoA = try makeTempGitRepo()
        let repoB = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repoB, named: "feature")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repoA, probe: AppModel.gitProbe)

        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)

        // Another repo's Space must not absorb it.
        XCTAssertEqual(model.spaces.count, 2)
        XCTAssertTrue(model.spaces.allSatisfy { $0.workspaces.count == 1 })
    }

    func testAddFolderSelectsAnAlreadyAdoptedWorktreeInsteadOfDuplicatingIt() throws {
        let repo = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repo, named: "adopted")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)
        let adoptedID = model.spaces[0].workspaces[1].id
        model.selectWorkspace(model.spaces[0].workspaces[0].id)

        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces[0].workspaces.count, 2)
        XCTAssertEqual(model.selectedWorkspaceID, adoptedID)
    }

    func testAddFolderAdoptsWorktreeOfCasperCreatedWorkspaceRepository() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        // A worktree created by Casper, then dropped from the sidebar without
        // deleting it on disk: re-adding its folder must bring it back into the
        // same Space rather than spawning a second Space for the same repo.
        let created = await model.addLinkedWorkspace(spaceID: model.spaces[0].id, name: "feat")
        XCTAssertTrue(created)
        let linked = model.spaces[0].workspaces[1]
        addTeardownBlock { try? FileManager.default.removeItem(atPath: linked.worktreePath) }
        model.removeWorkspace(id: linked.id)
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)

        model.addSpace(folderURL: URL(fileURLWithPath: linked.worktreePath), probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces.count, 1)
        XCTAssertEqual(model.spaces[0].workspaces.count, 2)
        XCTAssertEqual(model.spaces[0].workspaces[1].branch, "feat")
    }

    // MARK: - Adding the repository of worktrees already open as Spaces

    func testAddFolderReunifiesAWorktreeSpaceIntoTheRepositorySpace() throws {
        let repo = try makeTempGitRepo()
        let worktree = try makeWorktree(of: repo, named: "solo")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        // The worktree is opened first, so it lands as a Space of its own.
        model.addSpace(folderURL: worktree, probe: AppModel.gitProbe)
        let stranded = model.spaces[0].workspaces[0]
        let strandedSurfaces = LayoutTree.surfaceIDs(stranded.layout)

        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces.count, 1)
        let space = model.spaces[0]
        // The reunified Space roots at the repository, not at the worktree.
        XCTAssertEqual(
            URL(fileURLWithPath: space.folderPath).resolvingSymlinksInPath().path,
            repo.resolvingSymlinksInPath().path)
        XCTAssertEqual(space.workspaces.count, 2)
        let primary = space.orderedWorkspaces[0]
        XCTAssertEqual(primary.kind, .primary)
        XCTAssertEqual(
            URL(fileURLWithPath: primary.worktreePath).resolvingSymlinksInPath().path,
            repo.resolvingSymlinksInPath().path)
        let reunified = try XCTUnwrap(space.workspaces.first(where: { $0.id == stranded.id }))
        XCTAssertEqual(reunified.kind, .linked)
        XCTAssertEqual(reunified.branch, "solo")
        // Renamed from the Space name (the repository) to its branch.
        XCTAssertEqual(reunified.name, "solo")
        XCTAssertEqual(reunified.baseBranch, primary.branch)
        // Moved whole: same identity, same port block, same live surfaces.
        XCTAssertEqual(reunified.portBase, stranded.portBase)
        XCTAssertEqual(LayoutTree.surfaceIDs(reunified.layout), strandedSurfaces)
        XCTAssertEqual(model.selectedWorkspaceID, primary.id)
        // The disk write is backgrounded; flush so the synchronous load is deterministic.
        model.flushPendingSave()
        let saved = try store.load()
        XCTAssertEqual(saved.spaces.count, 1)
        XCTAssertEqual(saved.spaces[0].workspaces.count, 2)
    }

    /// A Git Space rooted at `path` with a single primary workspace, for sessions
    /// built by hand (a state `addSpace` itself no longer produces).
    private func gitSpace(name: String, path: String, branch: String, portBase: Int) -> Space {
        let workspace = Workspace(
            name: name, worktreePath: path, branch: branch, portBase: portBase,
            layout: .leaf(Surface(kind: .terminal(cwd: path))), kind: .primary)
        return Space(name: name, folderPath: path, isGitRepo: true, workspaces: [workspace])
    }

    func testAddFolderReunifiesEveryWorktreeSpaceOfTheSameRepository() throws {
        let repo = try makeTempGitRepo()
        let one = try makeWorktree(of: repo, named: "one")
        let two = try makeWorktree(of: repo, named: "two")
        let unrelated = try makeTempGitRepo()
        // A session from before worktrees were grouped: each worktree of the same
        // repository sits in a Space of its own, next to an unrelated repository.
        let session = Session(spaces: [
            gitSpace(name: "one", path: one.path, branch: "one", portBase: 41000),
            gitSpace(name: "two", path: two.path, branch: "two", portBase: 41010),
            gitSpace(name: "other", path: unrelated.path, branch: "main", portBase: 41020),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)

        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)

        // Both worktree Spaces collapse into the repository's; the unrelated
        // repository is left alone.
        XCTAssertEqual(model.spaces.count, 2)
        let space = try XCTUnwrap(model.spaces.first(where: {
            URL(fileURLWithPath: $0.folderPath).resolvingSymlinksInPath().path
                == repo.resolvingSymlinksInPath().path
        }))
        XCTAssertEqual(space.workspaces.count, 3)
        XCTAssertEqual(space.workspaces.filter { $0.kind == .primary }.count, 1)
        XCTAssertEqual(
            Set(space.workspaces.filter { $0.kind == .linked }.map(\.branch)), ["one", "two"])
        XCTAssertEqual(
            model.spaces.first(where: { $0.id != space.id })?.workspaces.count, 1)
    }

    func testAddFolderGroupsWorktreesTogetherEvenBeforeTheirRepositoryIsOpen() throws {
        let repo = try makeTempGitRepo()
        let one = try makeWorktree(of: repo, named: "one")
        let two = try makeWorktree(of: repo, named: "two")
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)

        model.addSpace(folderURL: one, probe: AppModel.gitProbe)
        model.addSpace(folderURL: two, probe: AppModel.gitProbe)

        // Same repository, so still a single Space — rooted at the first worktree,
        // since only the repository's main working tree can take that place and it
        // is not open.
        XCTAssertEqual(model.spaces.count, 1)
        XCTAssertEqual(model.spaces[0].workspaces.count, 2)
        XCTAssertEqual(
            URL(fileURLWithPath: model.spaces[0].folderPath).resolvingSymlinksInPath().path,
            one.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.spaces[0].workspaces[1].branch, "two")
    }

    func testReunifiedWorkspacesKeepTheirOwnRecordedBaseBranch() throws {
        let repo = try makeTempGitRepo()
        let host = try makeWorktree(of: repo, named: "host")
        let child = try makeWorktree(of: repo, named: "child")
        // A Space rooted at the `host` worktree that already carries a linked
        // workspace of its own, forked from `host` rather than from the repository's
        // default branch.
        let hostWorkspace = Workspace(
            name: "host-space", worktreePath: host.path, branch: "host", portBase: 41000,
            layout: .leaf(Surface(kind: .terminal(cwd: host.path))), kind: .primary)
        let childWorkspace = Workspace(
            name: "child", worktreePath: child.path, branch: "child", portBase: 41010,
            layout: .leaf(Surface(kind: .terminal(cwd: child.path))), kind: .linked,
            baseBranch: "host")
        let session = Session(spaces: [
            Space(name: "host-space", folderPath: host.path, isGitRepo: true,
                  workspaces: [hostWorkspace, childWorkspace]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)

        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)

        XCTAssertEqual(model.spaces.count, 1)
        let space = model.spaces[0]
        XCTAssertEqual(space.workspaces.count, 3)
        let primary = space.orderedWorkspaces[0]
        // The ex-primary inherits the repository's branch as its base…
        let reunifiedHost = try XCTUnwrap(space.workspaces.first(where: { $0.id == hostWorkspace.id }))
        XCTAssertEqual(reunifiedHost.kind, .linked)
        XCTAssertEqual(reunifiedHost.name, "host")
        XCTAssertEqual(reunifiedHost.baseBranch, primary.branch)
        // …while a workspace that already recorded a base keeps it: that is still
        // the branch it forked from and merges back into.
        let reunifiedChild = try XCTUnwrap(space.workspaces.first(where: { $0.id == childWorkspace.id }))
        XCTAssertEqual(reunifiedChild.kind, .linked)
        XCTAssertEqual(reunifiedChild.baseBranch, "host")
    }

    // MARK: - Promotion on worktree change (degenerate space gaining .git)

    func testSelectingDegenerateSpaceThatGainedGitPromotesIt() {
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

    func testWorktreeChangePromotesDegenerateSpaceAndBumpsRevision() async {
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

        // The bump is debounced (~0.2s).
        await waitUntil { model.diffRevision > revisionBefore }
        XCTAssertTrue(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "main")
        XCTAssertGreaterThan(model.diffRevision, revisionBefore)
    }

    func testWorktreeChangeBumpsDiffRevisionForGitSpace() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        var captured: (@Sendable () -> Void)?
        model.makeWorktreeWatcher = { _, _, onChange in
            captured = onChange
            return StubDirectoryWatcher()
        }
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        XCTAssertTrue(model.spaces[0].isGitRepo)
        let revisionBefore = model.diffRevision

        captured?()

        // The bump is debounced (~0.2s).
        await waitUntil { model.diffRevision > revisionBefore }
    }

    // MARK: - Demotion on worktree change (Git space losing .git)

    func testWorktreeChangeDemotesSpaceWhenGitRemoved() async throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

        // The reaction is debounced (~0.2s).
        await waitUntil { model.diffRevision > revisionBefore }
        XCTAssertFalse(model.spaces[0].isGitRepo)
        XCTAssertEqual(model.spaces[0].workspaces[0].branch, "")
        XCTAssertGreaterThan(model.diffRevision, revisionBefore)
    }

    func testSelectionDoesNotDemoteOnTransientProbeFailure() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        XCTAssertTrue(model.spaces[0].isGitRepo)

        // A transient probe failure at selection/launch time must NOT demote:
        // demotion happens only on a live filesystem event, never on a probe.
        model.gitReprobe = { _ in nil }
        model.selectWorkspace(model.spaces[0].workspaces[0].id)
        XCTAssertTrue(model.spaces[0].isGitRepo)
    }

    func testLaunchPromotesAllDegenerateSpacesThatGainedGit() {
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

    // MARK: - Watcher arm guarded by window visibility

    func testArmWorktreeWatcherSkipsWhileWindowHidden() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        var watcherCreated = false
        model.makeWorktreeWatcher = { _, _, _ in
            watcherCreated = true
            return StubDirectoryWatcher()
        }
        model.isWindowVisible = false
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)  // selects & would arm the watcher
        XCTAssertFalse(watcherCreated)
    }

    func testArmWorktreeWatcherRunsWhileWindowVisible() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        var watcherCreated = false
        model.makeWorktreeWatcher = { _, _, _ in
            watcherCreated = true
            return StubDirectoryWatcher()
        }
        model.isWindowVisible = true
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)  // selects & arms the watcher
        XCTAssertTrue(watcherCreated)
    }

    func testApplyWatcherVisibilityIsNoOpWhenUnchanged() {
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)  // isWindowVisible defaults to true
        let revisionBefore = model.diffRevision
        // No transition (still visible), so the guard blocks both calls.
        model.applyWatcherVisibility()
        model.applyWatcherVisibility()
        XCTAssertEqual(model.diffRevision, revisionBefore)
    }

    func testApplyWatcherVisibilityBumpsOnceOnRealTransition() throws {
        let repo = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        var watcherCreated = false
        model.makeWorktreeWatcher = { _, _, _ in
            watcherCreated = true
            return StubDirectoryWatcher()
        }
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)  // selects a worktree

        // Real true→false transition: stops the watchers (no re-arm on this path).
        model.isWindowVisible = false
        model.applyWatcherVisibility()

        watcherCreated = false
        let revisionBefore = model.diffRevision

        // Real false→true transition: re-arms and bumps the diff exactly once.
        model.isWindowVisible = true
        model.applyWatcherVisibility()
        XCTAssertTrue(watcherCreated)
        XCTAssertEqual(model.diffRevision, revisionBefore + 1)

        // No further transition: the guard blocks the repeat.
        model.applyWatcherVisibility()
        XCTAssertEqual(model.diffRevision, revisionBefore + 1)
    }

    // MARK: - Focus and layout mutations (Task 3)

    private func modelWithOneGitWorkspace() throws -> (AppModel, UUID) {
        let root = try makeTempGitRepo()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
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

    /// Adding a terminal by splitting must blur the previously-focused surface's
    /// cached view up front, or libghostty keeps rendering a solid caret on the
    /// old surface after focus has moved to the new one (the layout restructure
    /// silently detaches the old view before `resignFirstResponder` would fire).
    func testApplyNewTerminalBlursPreviouslyFocusedSurface() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()

        let workspace = model.spaces[0].workspaces[0]
        let surface = LayoutTree.surfaces(workspace.layout).first { $0.id == first }!
        let view = model.surfaceView(for: surface, in: workspace.id)!

        model.applyNewTerminal()

        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// A pane that is not the model's focused surface must be blurred the moment
    /// its view attaches to a window, or libghostty renders a solid caret on it.
    /// A brand-new surface defaults to "focused", and `onAttach` only pushes
    /// focus to the pane matching `focusedSurfaceID` — so at cold launch or the
    /// first mount of a multi-pane workspace, every other pane is created fresh
    /// and never told it lacks focus. Attaching a non-focused pane's view must
    /// push an explicit `false`.
    func testAttachingANonFocusedSurfaceViewBlursIt() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()

        model.applyNewSplit(.right)  // now two surfaces; focus moved to the new one
        let workspace = model.spaces[0].workspaces[0]
        let surface = LayoutTree.surfaces(workspace.layout).first { $0.id == first }!
        let view = model.surfaceView(for: surface, in: workspace.id)!

        // `first`'s view was never created before the split, so this simulates a
        // pane's view attaching to a window for the first time in a fresh process
        // (cold launch / session restore) while it is NOT the model's focused
        // surface — exactly what `GhosttySurfaceView.viewDidMoveToWindow` triggers
        // via `onAttach`.
        view.onAttach(first)

        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    #if DEBUG
    // Gated because `debugSurfaceViewCount` is, so `swift test -c release` still
    // compiles this file.
    /// Closing a pane must not leave a cached view behind. When SwiftUI tears the
    /// pane down it evaluates the departing `SurfaceHostView`'s body one last time,
    /// and that body still holds the `Surface` value captured when the pane tree was
    /// built — so it asks the model for a view for a surface the model has already
    /// removed. Answering with a freshly built view re-fills the cache slot
    /// `applyCloseSurface` just emptied, and nothing ever empties it again: every
    /// closed terminal would permanently leak a zombie `GhosttySurfaceView` (an
    /// NSView, its closures retaining the model, and a process-wide `.keyUp` monitor)
    /// for the life of the process.
    func testSurfaceViewDoesNotRecreateAViewForAClosedSurface() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()
        model.applyNewSplit(.right)  // two surfaces; focus moves to the new one

        let workspace = model.spaces[0].workspaces[0]
        let surfaces = LayoutTree.surfaces(workspace.layout)
        let survivor = try XCTUnwrap(surfaces.first { $0.id == first })
        let closing = try XCTUnwrap(surfaces.first { $0.id != first })
        // Mount both panes, so the count below distinguishes "the closed surface was
        // dropped" from "the cache happens to be empty".
        XCTAssertNotNil(model.surfaceView(for: survivor, in: workspace.id))
        XCTAssertNotNil(model.surfaceView(for: closing, in: workspace.id))
        XCTAssertEqual(model.debugSurfaceViewCount, 2)

        model.applyCloseSurface(closing.id)
        XCTAssertEqual(model.debugSurfaceViewCount, 1)

        // Exactly what the departing `SurfaceHostView.content` does: the same stale
        // `Surface` value, re-asked after the model has forgotten the surface.
        XCTAssertNil(model.surfaceView(for: closing, in: workspace.id))
        XCTAssertEqual(model.debugSurfaceViewCount, 1)
    }
    #endif

    /// Full wiring, real libghostty surface: adjusting font size through the
    /// live view must update the exact matching `Surface` in the model and
    /// schedule a save — the whole capture path (Task 4's
    /// `onFontSizeChange` -> Task 5's `updateSurfaceFontSize` -> Task 3's
    /// `LayoutTree.updateSurface`) exercised together, not just unit-by-unit.
    @MainActor
    func testLiveFontSizeChangeFlowsFromViewIntoModelAndSchedulesSave() throws {
        let (model, surfaceID) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        let workspace = model.spaces[0].workspaces[0]
        let surface = LayoutTree.surfaces(workspace.layout).first { $0.id == surfaceID }!
        let view = try XCTUnwrap(model.surfaceView(for: surface, in: workspace.id))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new
        // `invalidate()` frees the libghostty surface while the view is still fully
        // alive, so no trampoline resolves a mid-deallocation view — the ordering
        // production teardown relies on (`surface-view-invalidate-before-release`).
        // Without it the login shell's PTY also outlives the test.
        defer {
            view.invalidate()
            window.contentView = nil
        }

        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard view.surface != nil else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        XCTAssertTrue(window.makeFirstResponder(view))  // performKeyEquivalent requires it

        // Cmd+Equal: the "=" key (unshifted "+") is keyCode 24 on a standard US
        // ANSI keyboard. A genuine NSEvent, built the same way a real keypress
        // arrives, so the whole capture path starts where the real one does.
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "=",
            charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        _ = view.performKeyEquivalent(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let updated = LayoutTree.surfaces(model.spaces[0].workspaces[0].layout)
            .first { $0.id == surfaceID }
        let updatedFontSize = try XCTUnwrap(updated?.fontSize)
        XCTAssertGreaterThan(updatedFontSize, 0)

        model.flushPendingSave()
        XCTAssertGreaterThanOrEqual(saves, 1)
    }

    /// Full wiring, real libghostty surface: a terminal opened with `--command`
    /// must have that command actually typed into and run by the real shell once
    /// its view is materialized — the end-to-end proof of the `initial_input`
    /// fix (replacing the vendored fork's broken `bash -l -c "exec"` path).
    @MainActor
    func testOpenTerminalWithCommandRunsItInTheRealShell() async throws {
        let (model, _) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()
        let workspaceID = model.spaces[0].workspaces[0].id

        let info = try XCTUnwrap(
            model.controlOpenTerminal(in: workspaceID, command: "echo COMMAND_RAN_$$"))
        let newID = try XCTUnwrap(UUID(uuidString: info.id))
        let workspace = model.spaces[0].workspaces[0]
        let surface = try XCTUnwrap(LayoutTree.surfaces(workspace.layout).first { $0.id == newID })
        let view = try XCTUnwrap(model.surfaceView(for: surface, in: workspace.id))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new
        // `invalidate()` frees the libghostty surface while the view is still fully
        // alive, so no trampoline resolves a mid-deallocation view — the ordering
        // production teardown relies on (`surface-view-invalidate-before-release`).
        // Without it the login shell's PTY also outlives the test.
        defer {
            view.invalidate()
            window.contentView = nil
        }

        // Not `waitUntil`: a surface that never comes up is an environment block
        // (`e2e-surface-creation-flakiness`), reported as a skip rather than a failure.
        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard view.surface != nil else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        // How long the shell takes to reach an interactive prompt and consume the
        // queued command varies with the user's login shell, so poll for the echo.
        await waitUntil(timeout: 10) { model.surfaceViewportText(newID)?.contains("COMMAND_RAN_") == true }

        let text = model.surfaceViewportText(newID) ?? ""
        XCTAssertTrue(
            text.contains("COMMAND_RAN_"),
            "expected the opened terminal's command to have run; viewport was:\n\(text)")
    }

    /// A context-menu split can target a pane other than the focused one. The
    /// blur must follow the surface that actually holds the caret, not the split
    /// anchor, otherwise the focused pane keeps a solid caret while focus moves.
    func testApplySplitFromNonFocusedSurfaceBlursTheFocusedSurface() throws {
        let (model, first) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()

        // Split once so there are two surfaces; focus moves to the new one.
        model.applyNewSplit(.right)
        let focused = model.focusedSurfaceID!
        XCTAssertNotEqual(focused, first)  // `first` is now the unfocused pane

        let workspace = model.spaces[0].workspaces[0]
        let focusedSurface = LayoutTree.surfaces(workspace.layout).first { $0.id == focused }!
        let focusedView = model.surfaceView(for: focusedSurface, in: workspace.id)!

        // Split FROM the non-focused pane (`first`), as a context-menu action does.
        model.applySplit(from: first, direction: .down)

        XCTAssertEqual(focusedView.debugLastFocusValue, false)
    }

    /// Closing the last pane of a standalone primary must keep the workspace (and
    /// its Space) alive, re-seeded with a fresh terminal.
    func testCloseLastSurfaceOfPrimaryReseedsTheWorkspace() throws {
        let (model, only) = try modelWithOneGitWorkspace()

        model.applyCloseFocusedSurface()  // the only surface of the only workspace

        XCTAssertEqual(model.spaces.count, 1)  // the Space survives
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
        let layout = model.spaces[0].workspaces[0].layout
        let ids = LayoutTree.surfaceIDs(layout)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNotEqual(ids[0], only)  // a fresh surface, not the closed one
        XCTAssertTrue(surfaceKindIsTerminal(layout, ids[0]))
    }

    /// Same for a linked workspace: closing its last pane re-seeds it instead of
    /// dropping it from the Space.
    func testCloseLastSurfaceOfLinkedWorkspaceReseedsTheWorkspace() {
        let primary = Workspace(
            name: "main", worktreePath: "/repo", branch: "main", portBase: 40000,
            layout: .leaf(Surface.terminal(cwd: "/repo")), kind: .primary)
        let linkedSurface = Surface.terminal(cwd: "/repo-feat")
        let linked = Workspace(
            name: "feat", worktreePath: "/repo-feat", branch: "feat", portBase: 40010,
            layout: .leaf(linkedSurface), kind: .linked)
        let session = Session(spaces: [
            Space(name: "repo", folderPath: "/repo", isGitRepo: true,
                  workspaces: [primary, linked]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)
        model.selectWorkspace(linked.id)
        model.focusSurface(linkedSurface.id)

        model.applyCloseSurface(linkedSurface.id)

        XCTAssertEqual(model.spaces.count, 1)
        XCTAssertEqual(model.spaces[0].workspaces.map(\.id), [primary.id, linked.id])
        let layout = model.spaces[0].workspaces[1].layout
        let ids = LayoutTree.surfaceIDs(layout)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNotEqual(ids[0], linkedSurface.id)  // a fresh surface, not the closed one
        XCTAssertTrue(surfaceKindIsTerminal(layout, ids[0]))
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
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })
        let sid = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0]
        model.focusSurface(sid)
        return (model, sid)
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

    func testToggleInspectorTabExpandsCollapsesAndSwitches() {
        let (model, _) = modelWithOnePlainWorkspace()
        let wsID = model.spaces[0].workspaces[0].id
        // Start collapsed → first toggle expands onto the diff tab.
        model.setInspectorCollapsed(true, for: wsID)
        model.toggleInspectorTab(.diff, for: wsID)
        XCTAssertFalse(model.spaces[0].workspaces[0].inspector.collapsed)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.tab, .diff)
        // Expanded on the same tab → toggle collapses.
        model.toggleInspectorTab(.diff, for: wsID)
        XCTAssertTrue(model.spaces[0].workspaces[0].inspector.collapsed)
        // Expanded on a DIFFERENT tab → toggle switches tab, stays expanded.
        model.setInspectorTab(.browser, for: wsID)
        model.toggleInspectorTab(.diff, for: wsID)
        XCTAssertFalse(model.spaces[0].workspaces[0].inspector.collapsed)
        XCTAssertEqual(model.spaces[0].workspaces[0].inspector.tab, .diff)
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

    // MARK: - Open in Editor

    func testResolvedEditorPrefersExplicitKindOverWorkspaceOverAvailable() {
        let (model, _) = modelWithOnePlainWorkspace()
        var workspace = model.spaces[0].workspaces[0]
        workspace.lastUsedEditor = .intellijIdea
        XCTAssertEqual(model.resolvedEditor(.xcode, for: workspace), .xcode)
    }

    func testResolvedEditorFallsBackToWorkspaceLastUsedEditor() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        model.completeLaunchSetup()   // the editor list is detected at launch, not in `init`
        // Pick a remembered editor that is available but not availableEditors.first, so
        // this stays distinguishable from the "falls back to first available" test case.
        guard let remembered = model.availableEditors.dropFirst().first else {
            throw XCTSkip("need at least two available editors to distinguish lastUsedEditor from availableEditors.first")
        }
        var workspace = model.spaces[0].workspaces[0]
        workspace.lastUsedEditor = remembered
        XCTAssertEqual(model.resolvedEditor(nil, for: workspace), remembered)
    }

    func testResolvedEditorFallsBackToFirstAvailableEditor() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        model.completeLaunchSetup()   // the editor list is detected at launch, not in `init`
        // Both sides are nil on a machine with no editor installed, which would assert
        // nothing — the same guard the neighbouring editor tests apply.
        guard let expected = model.availableEditors.first else {
            throw XCTSkip("no available editor to test with on this machine")
        }
        let workspace = model.spaces[0].workspaces[0]
        XCTAssertNil(workspace.lastUsedEditor)
        XCTAssertEqual(model.resolvedEditor(nil, for: workspace), expected)
    }

    func testResolvedEditorIgnoresStaleLastUsedEditorNotInAvailableEditors() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        model.completeLaunchSetup()   // the editor list is detected at launch, not in `init`
        guard let stale = EditorKind.allCases.first(where: { !model.availableEditors.contains($0) }) else {
            throw XCTSkip("no uninstalled editor to test with on this machine")
        }
        var workspace = model.spaces[0].workspaces[0]
        workspace.lastUsedEditor = stale
        XCTAssertNotEqual(model.resolvedEditor(nil, for: workspace), stale)
        XCTAssertEqual(model.resolvedEditor(nil, for: workspace), model.availableEditors.first)
    }

    func testSelectEditorChangesDefaultWithoutLaunching() throws {
        let (model, _) = modelWithOnePlainWorkspace()
        model.completeLaunchSetup()   // the editor list is detected at launch, not in `init`
        guard let kind = model.availableEditors.first else {
            throw XCTSkip("no available editor to test with on this machine")
        }
        var saves = 0
        model.onPersistForTest = { saves += 1 }
        model.selectEditor(kind, for: model.spaces[0].workspaces[0].id)
        XCTAssertEqual(model.spaces[0].workspaces[0].lastUsedEditor, kind)
        XCTAssertEqual(saves, 1)
    }

    // MARK: - Reserved port block injection

    func testSurfaceConfigurationInjectsPortBlockForLinkedWorkspacesOnly() {
        let primary = Workspace(
            name: "main", worktreePath: "/repo", branch: "main", portBase: 40000,
            layout: .leaf(Surface.terminal(cwd: "/repo")), kind: .primary)
        let linked = Workspace(
            name: "feat", worktreePath: "/repo-feat", branch: "feat", portBase: 40010,
            layout: .leaf(Surface.terminal(cwd: "/repo-feat")), kind: .linked)
        let session = Session(spaces: [
            Space(name: "repo", folderPath: "/repo", isGitRepo: true,
                  workspaces: [primary, linked]),
        ])
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store, session: session)

        let primaryEnv = model.surfaceConfiguration(
            for: primary, terminal: Surface.terminal(cwd: primary.worktreePath)).environment
        let linkedEnv = model.surfaceConfiguration(
            for: linked, terminal: Surface.terminal(cwd: linked.worktreePath)).environment

        XCTAssertNil(primaryEnv["CASPER_PORT"])
        XCTAssertEqual(linkedEnv["CASPER_PORT"], String(linked.portBase))
    }

    // MARK: - Terminal font-size persistence

    func testSurfaceConfigurationPassesPersistedFontSizeOrDefaultsToZero() {
        let (model, _) = modelWithOnePlainWorkspace()
        let workspace = model.spaces[0].workspaces[0]
        let sized = Surface(kind: .terminal(cwd: workspace.worktreePath), fontSize: 22)
        let unsized = Surface(kind: .terminal(cwd: workspace.worktreePath))

        XCTAssertEqual(model.surfaceConfiguration(for: workspace, terminal: sized).fontSize, 22)
        XCTAssertEqual(model.surfaceConfiguration(for: workspace, terminal: unsized).fontSize, 0)
    }

    func testUpdateSurfaceFontSizeUpdatesLayoutAndSchedulesSave() {
        let (model, surfaceID) = modelWithOnePlainWorkspace()
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        model.updateSurfaceFontSize(surfaceID, size: 20)

        let surface = LayoutTree.surfaces(model.spaces[0].workspaces[0].layout)
            .first { $0.id == surfaceID }
        XCTAssertEqual(surface?.fontSize, 20)

        model.flushPendingSave()  // debounced; flush so the assertion is deterministic
        XCTAssertEqual(saves, 1)
    }

    func testUpdateSurfaceFontSizeUnknownSurfaceIsNoOp() {
        let (model, _) = modelWithOnePlainWorkspace()
        let layoutBefore = model.spaces[0].workspaces[0].layout
        model.updateSurfaceFontSize(UUID(), size: 20)
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
    }

    // MARK: - Split ratio persistence

    /// A single-pane plain workspace split once into a two-pane horizontal split
    /// (even `[0.5, 0.5]` ratios), returning the model and its workspace id.
    private func modelWithTwoPaneSplit() -> (AppModel, UUID) {
        let (model, _) = modelWithOnePlainWorkspace()
        model.applyNewSplit(.right)  // leaf -> horizontal split of two panes
        return (model, model.spaces[0].workspaces[0].id)
    }

    func testSetSplitRatiosUpdatesTargetWorkspaceAndSchedulesSave() {
        let (model, wsID) = modelWithTwoPaneSplit()
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        model.setSplitRatios(at: [], ratios: [0.25, 0.75], for: wsID)

        guard case .split(_, _, let ratios) = model.spaces[0].workspaces[0].layout else {
            return XCTFail("workspace layout must remain a split")
        }
        XCTAssertEqual(ratios, [0.25, 0.75])

        model.flushPendingSave()  // debounced; flush so the assertion is deterministic
        XCTAssertGreaterThanOrEqual(saves, 1)
    }

    func testSetSplitRatiosNonPositiveSumIsNoOp() {
        let (model, wsID) = modelWithTwoPaneSplit()
        let layoutBefore = model.spaces[0].workspaces[0].layout
        model.setSplitRatios(at: [], ratios: [0, 0], for: wsID)  // sum 0 -> rejected
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
    }

    func testSetSplitRatiosUnchangedRatiosIsNoOp() {
        let (model, wsID) = modelWithTwoPaneSplit()
        let layoutBefore = model.spaces[0].workspaces[0].layout
        // The split is already even, so normalizing [0.5, 0.5] reproduces the
        // current ratios and the write must be skipped.
        model.setSplitRatios(at: [], ratios: [0.5, 0.5], for: wsID)
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
    }

    func testSetSplitRatiosInvalidPathIsNoOp() {
        let (model, wsID) = modelWithTwoPaneSplit()
        let layoutBefore = model.spaces[0].workspaces[0].layout
        // A stale child index does not resolve to a node -> tree unchanged.
        model.setSplitRatios(at: [9], ratios: [0.3, 0.7], for: wsID)
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
    }

    // MARK: - Diff surfaces (UI-5 Task 1)

    func testComputeDiffReturnsChangesForDirtyWorktree() async throws {
        let dir = try makeTempGitRepo()
        try "changed\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let ws = model.spaces[0].workspaces[0]
        let diff = await model.diffService.computeDiff(for: ws)
        XCTAssertNotNil(diff)
        XCTAssertFalse(diff!.files.isEmpty)
    }

    // Precondition behind DiffSurfaceView's refresh dedup (diff-view refresh-hang
    // incident): recomputing an unchanged worktree must yield an `==` diff, so the
    // view can treat a byte-identical recompute as a no-op instead of re-driving the
    // animated `LazyVStack` relayout that hangs the main thread.
    func testComputeDiffIsStableForUnchangedWorktree() async throws {
        let dir = try makeTempGitRepo()
        try "changed\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let ws = model.spaces[0].workspaces[0]
        let first = await model.diffService.computeDiff(for: ws)
        let second = await model.diffService.computeDiff(for: ws)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testComputeDiffNilForNonGitWorkspace() async {
        let dir = makeTemporaryDirectory()
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })
        let diff = await model.diffService.computeDiff(for: model.spaces[0].workspaces[0])
        XCTAssertNil(diff)
    }

    func testDiffSummaryCountsChangedLines() async throws {
        let dir = try makeTempGitRepo()
        try "seed\nadded\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: dir, probe: AppModel.gitProbe)
        let summary = await model.diffService.diffSummary(for: model.spaces[0].workspaces[0])
        XCTAssertEqual(summary?.insertions, 1)
        XCTAssertEqual(summary?.deletions, 0)
    }

    // MARK: - Named-command live refresh (scriptsRevision)

    /// Write `.casper.json` into `dir` with the given `scripts` object body,
    /// e.g. `#"{"run":"npm run dev"}"#`, matching `RepoConfigTests`' JSON shape.
    private func writeCasperScripts(at dir: URL, _ scriptsJSON: String) throws {
        let json = #"{"workspace":{"scripts":\#(scriptsJSON)}}"#
        try json.write(
            to: dir.appendingPathComponent(".casper.json"), atomically: true, encoding: .utf8)
    }

    /// A Git-backed model whose single workspace already has a `.casper.json`
    /// with the given `scripts` body. Returns the model, its workspace id, and
    /// the worktree URL so the test can rewrite/delete the config on disk.
    private func gitModelWithScripts(_ scriptsJSON: String) throws -> (AppModel, UUID, URL) {
        let repo = try makeTempGitRepo()
        try writeCasperScripts(at: repo, scriptsJSON)
        let (store, _) = makeTemporarySessionStore()
        let model = makeModel(store: store)
        model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
        return (model, model.spaces[0].workspaces[0].id, repo)
    }

    func testRefreshReflectsChangedScriptSetAndBumpsRevisionOnce() throws {
        let (model, wsID, worktree) = try gitModelWithScripts(#"{"run":"npm run dev"}"#)
        XCTAssertEqual(model.namedCommands(for: wsID).map(\.name), ["run"])  // primes the cache
        let revisionBefore = model.scriptsRevision

        // Rewrite to a different set (rename `run` away, add two new commands).
        try writeCasperScripts(at: worktree, #"{"serve":"npm run serve","test":"npm test"}"#)
        model.refreshNamedCommandsIfChanged(for: wsID)

        XCTAssertEqual(model.namedCommands(for: wsID).map(\.name), ["serve", "test"])
        XCTAssertEqual(model.scriptsRevision, revisionBefore + 1)
    }

    func testRefreshOnUnchangedFileIsNoOp() throws {
        let (model, wsID, worktree) = try gitModelWithScripts(#"{"run":"npm run dev"}"#)
        _ = model.namedCommands(for: wsID)  // primes the cache

        // First refresh reflects a real change and bumps the revision.
        try writeCasperScripts(at: worktree, #"{"serve":"npm run serve"}"#)
        model.refreshNamedCommandsIfChanged(for: wsID)
        let revisionAfterChange = model.scriptsRevision

        // Second refresh sees the same file: no cache churn, no revision bump.
        model.refreshNamedCommandsIfChanged(for: wsID)
        XCTAssertEqual(model.scriptsRevision, revisionAfterChange)
    }

    func testRefreshAfterDeletionHidesScriptsAndBumpsRevision() throws {
        let (model, wsID, worktree) = try gitModelWithScripts(#"{"run":"npm run dev"}"#)
        XCTAssertFalse(model.namedCommands(for: wsID).isEmpty)  // primes the cache
        let revisionBefore = model.scriptsRevision

        try FileManager.default.removeItem(at: worktree.appendingPathComponent(".casper.json"))
        model.refreshNamedCommandsIfChanged(for: wsID)

        XCTAssertTrue(model.namedCommands(for: wsID).isEmpty)
        XCTAssertEqual(model.scriptsRevision, revisionBefore + 1)
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
