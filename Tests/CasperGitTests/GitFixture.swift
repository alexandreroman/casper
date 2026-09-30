import Foundation
import XCTest
import Clibgit2
@testable import CasperGit

/// Builds real git repositories for tests using libgit2 only (no `git` binary).
enum GitFixture {
    /// Initialize a repo at `path`, write a README, and create one commit on the
    /// repository's default branch. Returns the open `Repository`.
    @discardableResult
    static func repository(at path: String) throws -> Repository {
        let repo = try Repository.initialize(atPath: path)
        try commit(repo, Data("casper fixture\n".utf8), to: "README.md", message: "Initial commit")
        return repo
    }

    /// Write `contents` to `path` (relative to the working tree), stage it and commit
    /// it onto HEAD, leaving the tree clean.
    static func commit(_ repo: Repository, _ contents: Data, to path: String, message: String) throws {
        let workdir = try XCTUnwrap(repo.workdirPath)
        try contents.write(to: URL(fileURLWithPath: workdir).appendingPathComponent(path))
        try stage(repo, adding: [path])
        try commitIndex(repo, message: message)
    }

    /// Stage the working tree's state of `added` and drop `removed` from the index.
    static func stage(_ repo: Repository, adding added: [String] = [], removing removed: [String] = []) throws {
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        for path in removed { try gitCheck(git_index_remove_bypath(index, path)) }
        for path in added { try gitCheck(git_index_add_bypath(index, path)) }
        try gitCheck(git_index_write(index))
    }

    /// Commit the index as it stands onto HEAD — as the root commit when HEAD is
    /// unborn.
    static func commitIndex(_ repo: Repository, message: String) throws {
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }

        // Build the tree from the index.
        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }

        // The parent, when HEAD already names a commit.
        var parents: [OpaquePointer?] = []
        var headRef: OpaquePointer?
        let headCode = git_repository_head(&headRef, repo.pointer)
        defer { git_reference_free(headRef) }
        if headCode != GIT_EUNBORNBRANCH.rawValue {
            try gitCheck(headCode)
            var parent: OpaquePointer?
            try gitCheck(git_reference_peel(&parent, headRef, GIT_OBJECT_COMMIT))
            parents.append(parent)
        }
        defer { parents.forEach { git_object_free($0) } }

        // Author/committer signature.
        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        // Commit onto HEAD (creating the default branch ref on the first commit).
        // Swift cannot import the variadic `git_commit_create_v`, so use the
        // array-based `git_commit_create`.
        var commitOid = git_oid()
        let parentCount = parents.count
        try gitCheck(parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(
                &commitOid, repo.pointer, "HEAD",
                signature, signature, nil, message, tree, parentCount, buffer.baseAddress)
        })
    }
}

final class GitFixtureTests: XCTestCase {
    func testFixtureCreatesRepoWithOneCommit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try GitFixture.repository(at: dir.path)

        // HEAD must now resolve (born branch).
        var head: OpaquePointer?
        XCTAssertEqual(git_repository_head(&head, repo.pointer), 0)
        git_reference_free(head)
    }
}
