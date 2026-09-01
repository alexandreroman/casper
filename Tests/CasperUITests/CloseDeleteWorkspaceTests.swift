import XCTest
import CasperCore
import Clibgit2
import UserNotifications
@testable import CasperGit
@testable import CasperUI

@MainActor
final class CloseDeleteWorkspaceTests: XCTestCase {
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

    /// Commit `content` to `filename` at `repoPath`, onto its current HEAD.
    private func commitFile(atPath repoPath: String, filename: String, content: String) throws {
        let repo = try Repository.open(atPath: repoPath)
        try content.write(
            to: URL(fileURLWithPath: repoPath).appendingPathComponent(filename),
            atomically: true, encoding: .utf8)

        var index: OpaquePointer?
        XCTAssertEqual(git_repository_index(&index, repo.pointer), 0)
        defer { git_index_free(index) }
        XCTAssertEqual(git_index_add_bypath(index, filename), 0)
        XCTAssertEqual(git_index_write(index), 0)

        var treeOid = git_oid()
        XCTAssertEqual(git_index_write_tree(&treeOid, index), 0)
        var tree: OpaquePointer?
        XCTAssertEqual(git_tree_lookup(&tree, repo.pointer, &treeOid), 0)
        defer { git_tree_free(tree) }

        var headRef: OpaquePointer?
        XCTAssertEqual(git_repository_head(&headRef, repo.pointer), 0)
        defer { git_reference_free(headRef) }
        var parent: OpaquePointer?
        XCTAssertEqual(git_reference_peel(&parent, headRef, GIT_OBJECT_COMMIT), 0)
        defer { git_object_free(parent) }

        var signature: UnsafeMutablePointer<git_signature>?
        XCTAssertEqual(git_signature_now(&signature, "Casper Test", "test@casper.local"), 0)
        defer { git_signature_free(signature) }

        var commitOid = git_oid()
        var parents: [OpaquePointer?] = [parent]
        XCTAssertEqual(parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &commitOid, repo.pointer, "HEAD",
                signature, signature, nil, "commit", tree, 1, buf.baseAddress)
        }, 0)
    }

    /// A model with one Git-backed Space. Unlike `ControlHandlerTests.seededGitModel`
    /// (which leaves the primary's `branch` empty to dodge the host's default-branch
    /// name), the primary's `branch` here is set to the real default branch name:
    /// `closeWorkspace` merges *into* `baseBranch`, which `createLinkedWorkspace`
    /// derives from the primary's `branch` field — an empty string would make
    /// `baseBranch` empty too, and `closeWorkspace` treats that as "nothing to merge
    /// into" and no-ops.
    private func seededGitModel() throws -> (AppModel, UUID, String) {
        let repoPath = makeTemporaryDirectory(prefix: "casper-close").path
        try makeRepo(at: repoPath)
        let mainBranch = try Repository.open(atPath: repoPath).headBranchName()

        let ws = Workspace(
            name: "main", worktreePath: repoPath, branch: mainBranch,
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: repoPath)))
        let space = Space(name: "main", folderPath: repoPath, isGitRepo: true, workspaces: [ws])
        return (makeModel(spaces: [space], selecting: ws.id), ws.id, repoPath)
    }

    /// Await `controlDeleteWorkspace`, which keeps a completion-based shape for
    /// `ControlServer` even though the work behind it is async.
    private func deleteViaControl(
        _ model: AppModel, id: UUID
    ) async -> Result<Void, AppModel.WorkspaceDeleteError> {
        await withCheckedContinuation { continuation in
            model.controlDeleteWorkspace(id: id) { continuation.resume(returning: $0) }
        }
    }

    func testCloseWorkspaceMergesThenDeletesFromDisk() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        let outcome = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(outcome, .success)

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))
        let repo = try Repository.open(atPath: repoPath)
        XCTAssertFalse(try repo.branchExists(created.branch))
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "new\n")
    }

    func testCloseWorkspaceReselectsPrimaryWhenClosingSelectedLinkedWorkspace() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        model.selectWorkspace(created.id)

        let outcome = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(outcome, .success)

        XCTAssertEqual(model.selectedWorkspaceID, primaryID)
    }

    func testCloseWorkspaceAbortsOnConflictAndDeletesNothing() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "README.md", content: "from feature\n")
        try commitFile(atPath: repoPath, filename: "README.md", content: "from main\n")

        guard case .mergeFailed = await model.closeWorkspace(id: created.id) else {
            return XCTFail("expected a merge failure")
        }

        // Nothing touched: workspace, worktree, and branch all still present.
        XCTAssertNotNil(model.workspace(id: created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(created.branch))
    }

    func testDeleteWorkspaceSkipsMergeAndDeletesFromDisk() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        guard case .success = await model.deleteWorkspace(id: created.id) else {
            return XCTFail("expected delete to succeed")
        }

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))
        let repo = try Repository.open(atPath: repoPath)
        XCTAssertFalse(try repo.branchExists(created.branch))
        // Never merged: the file committed only on the branch never reaches the base.
        XCTAssertNil(try repo.fileTextAtHead(path: "feature.txt"))
    }

    func testDeleteWorkspaceReselectsPrimaryWhenDeletingSelectedLinkedWorkspace() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        model.selectWorkspace(created.id)

        guard case .success = await model.deleteWorkspace(id: created.id) else {
            return XCTFail("expected delete to succeed")
        }

        XCTAssertEqual(model.selectedWorkspaceID, primaryID)
    }

    func testCloseWorkspaceResyncsCleanPrimaryWorktree() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        let outcome = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(outcome, .success)

        // The primary's own working directory (not just its HEAD tree) now
        // has the merged file — the whole point of the resync.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: repoPath).appendingPathComponent("feature.txt").path))
    }

    func testCloseWorkspaceBlocksMergeWhenPrimaryIsDirty() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let dirtyPath = URL(fileURLWithPath: repoPath).appendingPathComponent("dirty.txt")
        try "uncommitted\n".write(to: dirtyPath, atomically: true, encoding: .utf8)

        guard case .mergeFailed = await model.closeWorkspace(id: created.id) else {
            return XCTFail("expected a merge failure")
        }

        // Nothing touched: workspace, worktree, and branch all still present,
        // and the merge never ran (feature.txt never reaches the primary's HEAD).
        XCTAssertNotNil(model.workspace(id: created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(created.branch))
        XCTAssertNil(try Repository.open(atPath: repoPath).fileTextAtHead(path: "feature.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath.path))
    }

    func testCloseWorkspaceBlocksMergeWhenClosingWorkspaceIsDirty() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let dirtyPath = URL(fileURLWithPath: created.worktreePath).appendingPathComponent("dirty.txt")
        try "uncommitted\n".write(to: dirtyPath, atomically: true, encoding: .utf8)

        guard case .mergeFailed = await model.closeWorkspace(id: created.id) else {
            return XCTFail("expected a merge failure")
        }

        // Nothing touched: workspace, worktree, and branch all still present,
        // and the merge never ran.
        XCTAssertNotNil(model.workspace(id: created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(created.branch))
        XCTAssertNil(try Repository.open(atPath: repoPath).fileTextAtHead(path: "feature.txt"))
    }

    // MARK: - Progress steps

    /// A `.casper.json` carrying only a `teardown` hook. Deliberately no `setup` hook:
    /// that one would spawn its own script split at workspace creation and blur which
    /// split the teardown assertions below are looking at.
    private func teardownConfig(_ command: String) -> String {
        "{\"workspace\": {\"scripts\": {\"teardown\": \"\(command)\"}}}\n"
    }

    /// Wait for the teardown split to appear and return its surface id, which is also
    /// the point where the operation is provably suspended on its teardown hook.
    ///
    /// The split lands within microseconds of the teardown step; the poll bound only
    /// exists so a broken run fails fast instead of stalling for the 30 s timeout.
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

    /// End the teardown split the way libghostty does at runtime.
    ///
    /// `runTeardown` really does spawn the split headlessly — `spawnScriptSurface` is a
    /// plain layout mutation — but no PTY runs in a unit test, so the child-exit event
    /// that ends the hook has to come from here. `handleScriptSurfaceExit` is the exact
    /// entry point `GhosttySurfaceView.onChildExit` calls in the app, so only the process
    /// is simulated, not the code under test.
    private func completeTeardownSplit(
        in model: AppModel, workspace workspaceID: UUID,
        surfacesBefore: Set<UUID>, exitCode: Int32
    ) async {
        guard let split = await awaitTeardownSplit(
            in: model, workspace: workspaceID, surfacesBefore: surfacesBefore)
        else { return }
        model.handleScriptSurfaceExit(split, code: exitCode)
    }

    func testCloseWorkspaceReportsFourStepsWhenThereIsNoTeardownHook() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let baseBranch = try XCTUnwrap(created.baseBranch)
        XCTAssertNil(model.teardownCommand(for: created), "the fixture repo has no .casper.json")

        var steps: [WorkspaceCloseProgress] = []
        model.onCloseProgressForTest = { steps.append($0) }

        let outcome = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(outcome, .success)

        XCTAssertEqual(steps.map(\.label), [
            "Checking for uncommitted changes\u{2026}",
            "Merging \u{201c}\(created.branch)\u{201d} into \u{201c}\(baseBranch)\u{201d}\u{2026}",
            "Removing the worktree\u{2026}",
            "Updating \u{201c}\(baseBranch)\u{201d}\u{2026}",
        ])
        XCTAssertEqual(steps.map(\.stepIndex), [1, 2, 3, 4])
        XCTAssertEqual(steps.map(\.stepCount), [4, 4, 4, 4])
        XCTAssertTrue(steps.allSatisfy { $0.id == created.id })
        XCTAssertTrue(steps.allSatisfy { $0.title == "Closing \u{201c}\(created.name)\u{201d}" })
        // Only the teardown step can time out, and there is none here.
        XCTAssertTrue(steps.allSatisfy { $0.deadline == nil })
        // The merge step names both ends of the merge, not just "Merging…".
        let mergeStep = try XCTUnwrap(steps.first { $0.label.hasPrefix("Merging") })
        XCTAssertEqual(mergeStep.stepIndex, 2)
        XCTAssertTrue(mergeStep.label.contains(created.branch), mergeStep.label)
        XCTAssertTrue(mergeStep.label.contains(baseBranch), mergeStep.label)
    }

    func testDeleteWorkspaceReportsOneStepWhenThereIsNoTeardownHook() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        XCTAssertNil(model.teardownCommand(for: created), "the fixture repo has no .casper.json")

        var steps: [WorkspaceCloseProgress] = []
        model.onCloseProgressForTest = { steps.append($0) }

        guard case .success = await model.deleteWorkspace(id: created.id) else {
            return XCTFail("expected delete to succeed")
        }

        XCTAssertEqual(steps.map(\.label), ["Removing the worktree\u{2026}"])
        XCTAssertEqual(steps.map(\.stepIndex), [1])
        XCTAssertEqual(steps.map(\.stepCount), [1])
        XCTAssertEqual(steps.first?.id, created.id)
        XCTAssertEqual(steps.first?.title, "Deleting \u{201c}\(created.name)\u{201d}")
        XCTAssertTrue(steps.allSatisfy { $0.deadline == nil })
    }

    /// The control channel reports its progress exactly like the sidebar action does: the
    /// JSON reply only ever reaches the CLI caller, so the sheet is all the person
    /// watching the app gets.
    func testControlDeleteWorkspaceReportsOneStepWhenThereIsNoTeardownHook() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        XCTAssertNil(model.teardownCommand(for: created), "the fixture repo has no .casper.json")

        var steps: [WorkspaceCloseProgress] = []
        model.onCloseProgressForTest = { steps.append($0) }

        guard case .success = await deleteViaControl(model, id: created.id) else {
            return XCTFail("expected delete to succeed")
        }

        XCTAssertEqual(steps.map(\.label), ["Removing the worktree\u{2026}"])
        XCTAssertEqual(steps.map(\.stepIndex), [1])
        XCTAssertEqual(steps.map(\.stepCount), [1])
        XCTAssertEqual(steps.first?.id, created.id)
        XCTAssertEqual(steps.first?.title, "Deleting \u{201c}\(created.name)\u{201d}")
        XCTAssertTrue(steps.allSatisfy { $0.deadline == nil })
    }

    func testCloseWorkspaceReportsFiveStepsWithATeardownHook() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        // Committed before the worktree is created, so the linked workspace checks it out.
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 0"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let baseBranch = try XCTUnwrap(created.baseBranch)
        XCTAssertEqual(model.teardownCommand(for: created), "exit 0", "the fixture's hook must resolve")

        var steps: [WorkspaceCloseProgress] = []
        model.onCloseProgressForTest = { steps.append($0) }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let close = Task { @MainActor in await model.closeWorkspace(id: created.id) }
        await completeTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore, exitCode: 0)
        let outcome = await close.value
        XCTAssertEqual(outcome, .success)

        XCTAssertEqual(steps.map(\.label), [
            "Checking for uncommitted changes\u{2026}",
            "Merging \u{201c}\(created.branch)\u{201d} into \u{201c}\(baseBranch)\u{201d}\u{2026}",
            "Running teardown hook\u{2026}",
            "Removing the worktree\u{2026}",
            "Updating \u{201c}\(baseBranch)\u{201d}\u{2026}",
        ])
        XCTAssertEqual(steps.map(\.stepIndex), [1, 2, 3, 4, 5])
        XCTAssertEqual(steps.map(\.stepCount), [5, 5, 5, 5, 5])
        // The hook is the only step that can time out, so it is the only one that
        // carries the countdown deadline.
        XCTAssertEqual(steps.map { $0.deadline != nil }, [false, false, true, false, false])
        let teardownStep = try XCTUnwrap(steps.first { $0.label.hasPrefix("Running teardown") })
        XCTAssertGreaterThan(try XCTUnwrap(teardownStep.deadline), Date(), "the countdown must be ahead")
        XCTAssertNil(model.workspace(id: created.id))
    }

    func testDeleteWorkspaceReportsTwoStepsWithATeardownHook() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 0"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        XCTAssertEqual(model.teardownCommand(for: created), "exit 0", "the fixture's hook must resolve")

        var steps: [WorkspaceCloseProgress] = []
        model.onCloseProgressForTest = { steps.append($0) }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let delete = Task { @MainActor in await model.deleteWorkspace(id: created.id) }
        await completeTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore, exitCode: 0)
        guard case .success = await delete.value else { return XCTFail("expected delete to succeed") }

        XCTAssertEqual(steps.map(\.label), [
            "Running teardown hook\u{2026}",
            "Removing the worktree\u{2026}",
        ])
        XCTAssertEqual(steps.map(\.stepIndex), [1, 2])
        XCTAssertEqual(steps.map(\.stepCount), [2, 2])
        XCTAssertEqual(steps.map { $0.deadline != nil }, [true, false])
        XCTAssertNil(model.workspace(id: created.id))
    }

    // MARK: - Sheet lifecycle

    /// End-to-end: a real close drives every step and leaves no sheet behind, however
    /// long the machine took over it. Whether a *fast* run publishes at all is timing
    /// by nature, so that rule is asserted deterministically against the reporter itself
    /// in `WorkspaceCloseProgressReporterTests`, not from here.
    func testCloseRunsEveryStepAndLeavesNoSheetBehind() async throws {
        let (model, primaryID, _) = try seededGitModel()
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        var stepCount = 0
        model.onCloseProgressForTest = { _ in stepCount += 1 }

        let outcome = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(outcome, .success)

        XCTAssertEqual(stepCount, 4, "the steps must run whether or not anything is shown")
        XCTAssertNil(model.closeProgress, "the sheet must be down once the operation returns")
    }

    // MARK: - Concurrent destroys

    /// Two deletes for the same workspace, overlapping for real: the second starts while
    /// the first is suspended on its teardown hook.
    ///
    /// The claim that rejects the second has to be taken synchronously at entry. Checking
    /// "is a teardown in flight?" instead lets both callers through — everything before
    /// the hook is `await`ed — and then the second one's latch overwrites the first's,
    /// stranding its continuation forever (a task that never returns, plus a leaked
    /// continuation). Hence the assertion that BOTH calls return, not just that the
    /// second is refused.
    func testASecondDeleteIsRejectedWhileTheFirstIsRunningAndNeitherCallerHangs() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 0"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let first = Task { @MainActor in await model.deleteWorkspace(id: created.id) }
        let spawned = await awaitTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore)
        let split = try XCTUnwrap(spawned)

        guard case .failure(let error) = await model.deleteWorkspace(id: created.id) else {
            return XCTFail("the second delete must be refused while the first is in flight")
        }
        XCTAssertEqual(error.message, "deletion already in progress")

        model.handleScriptSurfaceExit(split, code: 0)
        guard case .success = await first.value else {
            return XCTFail("the first delete must still complete")
        }
        XCTAssertNil(model.workspace(id: created.id))
    }

    /// The same claim seen from the close path, which owns the other rejection message —
    /// and where letting a second caller through would also run two libgit2 writers
    /// against one repository from two detached threads.
    func testASecondCloseIsRejectedWhileTheFirstIsRunningAndNeitherCallerHangs() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 0"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let first = Task { @MainActor in await model.closeWorkspace(id: created.id) }
        let spawned = await awaitTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore)
        let split = try XCTUnwrap(spawned)

        let second = await model.closeWorkspace(id: created.id)
        XCTAssertEqual(second, .mergeFailed(message: "This workspace is already being closed."))

        model.handleScriptSurfaceExit(split, code: 0)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .success, "the first close must still complete")
        XCTAssertNil(model.workspace(id: created.id))
    }

    // MARK: - Teardown hook failure reporting

    /// The presenters (`presentCloseWorkspaceConfirmation` /
    /// `presentDeleteWorkspaceConfirmation`) cannot run headlessly — they open an
    /// `NSAlert` with `runModal()` — so the two tests below drive the same close/delete
    /// call with the same `onTeardownHook` closure the presenters install, which is what
    /// actually turns a hook status into a notification.
    func testFailingTeardownHookStillClosesAndNotifiesOnce() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 2"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        var notifications: [(title: String, body: String, id: UUID, level: UNNotificationInterruptionLevel)] = []
        model.deliverNotification = { notifications.append((title: $0, body: $1, id: $2, level: $3)) }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let close = Task { @MainActor in
            await model.closeWorkspace(id: created.id) { status in
                model.reportTeardownHookFailure(
                    status, workspace: created.name, id: created.id, verb: "closed")
            }
        }
        await completeTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore, exitCode: 2)
        let outcome = await close.value

        XCTAssertEqual(outcome, .success, "a broken teardown hook never blocks the close")
        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))

        XCTAssertEqual(notifications.count, 1)
        let notification = try XCTUnwrap(notifications.first)
        XCTAssertEqual(notification.title, "Teardown hook failed")
        XCTAssertTrue(notification.body.contains(created.name), notification.body)
        XCTAssertTrue(notification.body.contains("exit 2"), notification.body)
        XCTAssertEqual(notification.id, created.id, "the workspace id routes a tap back")
        XCTAssertEqual(notification.level, .active, "a passive notification would never be seen")
    }

    func testSucceedingTeardownHookDeletesWithoutNotifying() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 0"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }

        var notifications = 0
        model.deliverNotification = { _, _, _, _ in notifications += 1 }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let delete = Task { @MainActor in
            await model.deleteWorkspace(id: created.id) { status in
                model.reportTeardownHookFailure(
                    status, workspace: created.name, id: created.id, verb: "deleted")
            }
        }
        await completeTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore, exitCode: 0)
        guard case .success = await delete.value else { return XCTFail("expected delete to succeed") }

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertEqual(notifications, 0, "a hook that exited cleanly has nothing to report")
    }

    /// The control channel installs that closure itself, so unlike the two tests above
    /// this one exercises the real call path rather than standing in for a presenter.
    func testFailingTeardownHookOnControlDeleteStillDeletesAndNotifiesOnce() async throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        let spaceID = try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id)
        try commitFile(atPath: repoPath, filename: ".casper.json", content: teardownConfig("exit 2"))
        guard case .success(let created) = await model.createLinkedWorkspace(
            spaceID: spaceID, name: "feature", base: nil)
        else { return XCTFail("setup failed") }

        var notifications: [(title: String, body: String, id: UUID, level: UNNotificationInterruptionLevel)] = []
        model.deliverNotification = { notifications.append((title: $0, body: $1, id: $2, level: $3)) }

        let surfacesBefore = Set(LayoutTree.surfaceIDs(created.layout))
        let delete = Task { @MainActor in await self.deleteViaControl(model, id: created.id) }
        await completeTeardownSplit(
            in: model, workspace: created.id, surfacesBefore: surfacesBefore, exitCode: 2)
        guard case .success = await delete.value else { return XCTFail("expected delete to succeed") }

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))

        XCTAssertEqual(notifications.count, 1)
        let notification = try XCTUnwrap(notifications.first)
        XCTAssertEqual(notification.title, "Teardown hook failed")
        XCTAssertTrue(notification.body.contains(created.name), notification.body)
        XCTAssertTrue(notification.body.contains("exit 2"), notification.body)
        XCTAssertEqual(notification.id, created.id, "the workspace id routes a tap back")
        XCTAssertEqual(notification.level, .active, "a passive notification would never be seen")
    }
}
