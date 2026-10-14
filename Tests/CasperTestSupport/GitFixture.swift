import CasperGit
import Clibgit2
import Foundation

/// A libgit2 call in a fixture returned a negative code.
public struct GitFixtureError: Error {
    public let code: Int32
    public let message: String
}

/// Builds real git repositories for tests using libgit2 only (no `git` binary).
///
/// A regular target rather than a test target, so every test target can share it.
/// `swift build -c release` compiles it too, which rules out `@testable import`: it
/// reaches only CasperGit's public API, and does its index and commit work on a raw
/// libgit2 handle of its own.
public enum GitFixture {
    /// Initialize a repo at `path`, write a README plus `files` (relative path →
    /// contents; an entry for `README.md` replaces the default one), and commit
    /// them all as the first commit on the repository's default branch. Returns the
    /// open `Repository`.
    @discardableResult
    public static func repository(at path: String, files: [String: String] = [:]) throws -> Repository {
        // `Repository.initialize` runs CasperGit's one-time libgit2 setup, which picks
        // the default branch name the way Casper itself does.
        let repo = try Repository.initialize(atPath: path)
        let committed = ["README.md": "casper fixture\n"].merging(files) { _, new in new }
        for (file, contents) in committed {
            try write(Data(contents.utf8), to: file, inRepoAt: path)
        }
        try stage(atPath: path, adding: Array(committed.keys))
        try commitIndex(atPath: path, message: "Initial commit")
        return repo
    }

    /// Write `contents` to `file` (relative to the working tree at `repoPath`), stage
    /// it and commit it onto HEAD, leaving the tree clean.
    public static func commit(
        atPath repoPath: String, file: String, contents: Data, message: String = "Test commit"
    ) throws {
        try write(contents, to: file, inRepoAt: repoPath)
        try stage(atPath: repoPath, adding: [file])
        try commitIndex(atPath: repoPath, message: message)
    }

    /// `commit(atPath:file:contents:message:)` for a text file.
    public static func commit(
        atPath repoPath: String, file: String, contents: String, message: String = "Test commit"
    ) throws {
        try commit(atPath: repoPath, file: file, contents: Data(contents.utf8), message: message)
    }

    /// Stage the working tree's state of `added` and drop `removed` from the index.
    public static func stage(
        atPath repoPath: String, adding added: [String] = [], removing removed: [String] = []
    ) throws {
        try withRepository(atPath: repoPath) { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            for path in removed { try check(git_index_remove_bypath(index, path)) }
            for path in added { try check(git_index_add_bypath(index, path)) }
            try check(git_index_write(index))
        }
    }

    /// Commit the index as it stands onto HEAD — as the root commit when HEAD is
    /// unborn.
    public static func commitIndex(atPath repoPath: String, message: String) throws {
        try withRepository(atPath: repoPath) { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }

            // Build the tree from the index.
            var treeOid = git_oid()
            try check(git_index_write_tree(&treeOid, index))
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, repo, &treeOid))
            defer { git_tree_free(tree) }

            // The parent, when HEAD already names a commit.
            var parents: [OpaquePointer?] = []
            defer { parents.forEach { git_object_free($0) } }
            var headRef: OpaquePointer?
            let headCode = git_repository_head(&headRef, repo)
            defer { git_reference_free(headRef) }
            if headCode != GIT_EUNBORNBRANCH.rawValue {
                try check(headCode)
                var parent: OpaquePointer?
                try check(git_reference_peel(&parent, headRef, GIT_OBJECT_COMMIT))
                parents.append(parent)
            }

            // Author/committer signature.
            var signature: UnsafeMutablePointer<git_signature>?
            try check(git_signature_now(&signature, "Casper Test", "test@casper.local"))
            defer { git_signature_free(signature) }

            // Commit onto HEAD (creating the default branch ref on the first commit).
            // Swift cannot import the variadic `git_commit_create_v`, so use the
            // array-based `git_commit_create`.
            var commitOid = git_oid()
            let parentCount = parents.count
            try check(parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOid, repo, "HEAD",
                    signature, signature, nil, message, tree, parentCount, buffer.baseAddress)
            })
        }
    }

    private static func write(_ contents: Data, to file: String, inRepoAt repoPath: String) throws {
        try contents.write(to: URL(fileURLWithPath: repoPath).appendingPathComponent(file))
    }

    /// Run `body` on a raw libgit2 handle of the repository at `path`, freed after.
    private static func withRepository(atPath path: String, _ body: (OpaquePointer) throws -> Void) throws {
        // Opened through CasperGit first, for its one-time libgit2 setup: a raw
        // `git_repository_open` before any CasperGit call would run uninitialized.
        _ = try Repository.open(atPath: path)
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, path))
        defer { git_repository_free(repo) }
        guard let repo else { throw GitFixtureError(code: -1, message: "no repository handle") }
        try body(repo)
    }

    private static func check(_ code: Int32) throws {
        guard code < 0 else { return }
        let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown error"
        throw GitFixtureError(code: code, message: message)
    }
}
