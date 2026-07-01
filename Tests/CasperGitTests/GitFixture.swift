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

        // Write a file into the working tree.
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "casper fixture\n".write(to: readme, atomically: true, encoding: .utf8)

        // Stage it via the index.
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, "README.md"))
        try gitCheck(git_index_write(index))

        // Build the tree from the index.
        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }

        // Author/committer signature.
        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        // Commit onto HEAD (creates the default branch ref). Swift cannot import
        // the variadic `git_commit_create_v`, so use the array-based
        // `git_commit_create` with zero parents (initial commit).
        var commitOid = git_oid()
        try gitCheck(git_commit_create(
            &commitOid, repo.pointer, "HEAD",
            signature, signature, nil, "Initial commit", tree, 0, nil))

        return repo
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
