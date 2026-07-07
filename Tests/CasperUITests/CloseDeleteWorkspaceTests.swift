import XCTest
import CasperCore
import Clibgit2
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
        let repoPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        try makeRepo(at: repoPath)
        let mainBranch = try Repository.open(atPath: repoPath).headBranchName()

        let ws = Workspace(
            name: "main", worktreePath: repoPath, branch: mainBranch,
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: repoPath)))
        let space = Space(name: "main", folderPath: repoPath, isGitRepo: true, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id, repoPath)
    }

    func testCloseWorkspaceMergesThenDeletesFromDisk() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        XCTAssertEqual(model.closeWorkspace(id: created.id), .success)

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))
        let repo = try Repository.open(atPath: repoPath)
        XCTAssertFalse(try repo.branchExists(created.branch))
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "new\n")
    }

    func testCloseWorkspaceAbortsOnConflictAndDeletesNothing() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "README.md", content: "from feature\n")
        try commitFile(atPath: repoPath, filename: "README.md", content: "from main\n")

        guard case .mergeFailed = model.closeWorkspace(id: created.id) else {
            return XCTFail("expected a merge failure")
        }

        // Nothing touched: workspace, worktree, and branch all still present.
        XCTAssertNotNil(model.workspace(id: created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(created.branch))
    }

    func testDeleteWorkspaceSkipsMergeAndDeletesFromDisk() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        guard case .success = model.deleteWorkspace(id: created.id) else {
            return XCTFail("expected delete to succeed")
        }

        XCTAssertNil(model.workspace(id: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))
        let repo = try Repository.open(atPath: repoPath)
        XCTAssertFalse(try repo.branchExists(created.branch))
        // Never merged: the file committed only on the branch never reaches the base.
        XCTAssertNil(try repo.fileTextAtHead(path: "feature.txt"))
    }

    func testCloseWorkspaceResyncsCleanPrimaryWorktree() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")

        XCTAssertEqual(model.closeWorkspace(id: created.id), .success)

        // The primary's own working directory (not just its HEAD tree) now
        // has the merged file — the whole point of the resync.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: repoPath).appendingPathComponent("feature.txt").path))
    }

    func testCloseWorkspaceBlocksMergeWhenPrimaryIsDirty() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let dirtyPath = URL(fileURLWithPath: repoPath).appendingPathComponent("dirty.txt")
        try "uncommitted\n".write(to: dirtyPath, atomically: true, encoding: .utf8)

        guard case .mergeFailed = model.closeWorkspace(id: created.id) else {
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

    func testCloseWorkspaceBlocksMergeWhenClosingWorkspaceIsDirty() throws {
        let (model, primaryID, repoPath) = try seededGitModel()
        guard case .success(let created) = model.createLinkedWorkspace(
            spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
            name: "feature", base: nil)
        else { return XCTFail("setup failed") }
        try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
        let dirtyPath = URL(fileURLWithPath: created.worktreePath).appendingPathComponent("dirty.txt")
        try "uncommitted\n".write(to: dirtyPath, atomically: true, encoding: .utf8)

        guard case .mergeFailed = model.closeWorkspace(id: created.id) else {
            return XCTFail("expected a merge failure")
        }

        // Nothing touched: workspace, worktree, and branch all still present,
        // and the merge never ran.
        XCTAssertNotNil(model.workspace(id: created.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        XCTAssertTrue(try Repository.open(atPath: repoPath).branchExists(created.branch))
        XCTAssertNil(try Repository.open(atPath: repoPath).fileTextAtHead(path: "feature.txt"))
    }
}
