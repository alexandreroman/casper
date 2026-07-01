import Clibgit2
import Foundation

/// A libgit2 repository handle. Owns the `git_repository*` and frees it on
/// deinit. Not `Sendable`: use from a single thread/actor.
public final class Repository {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_repository_free(pointer)
    }

    /// Initialize a new non-bare repository at `path` (creating it if needed).
    public static func initialize(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_init(&repo, path, 0))
        return Repository(pointer: repo!)
    }

    /// Open an existing repository whose git dir is exactly at `path`.
    public static func open(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_open(&repo, path))
        return Repository(pointer: repo!)
    }

    /// Open the repository that owns `path`, searching upward through parents.
    public static func discover(startingAt path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        // flags 0 → search parent directories; no ceiling dirs.
        try gitCheck(git_repository_open_ext(&repo, path, 0, nil))
        return Repository(pointer: repo!)
    }

    /// Absolute path to the `.git` directory (trailing slash, per libgit2).
    public var gitDirPath: String {
        String(cString: git_repository_path(pointer))
    }

    /// Absolute path to the working directory, or nil for a bare repository.
    public var workdirPath: String? {
        guard let cString = git_repository_workdir(pointer) else { return nil }
        return String(cString: cString)
    }

    /// Short name of the branch HEAD currently points to.
    public func headBranchName() throws -> String {
        var head: OpaquePointer?
        try gitCheck(git_repository_head(&head, pointer))
        defer { git_reference_free(head) }
        var shorthand: UnsafePointer<CChar>?
        shorthand = git_reference_shorthand(head)
        guard let shorthand else {
            throw GitError(code: -1, message: "HEAD has no shorthand name")
        }
        return String(cString: shorthand)
    }

    /// Whether a local branch named `name` exists.
    public func branchExists(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        return true
    }

    /// Whether local branch `name` is checked out in any working tree. Returns
    /// false if the branch does not exist.
    public func isBranchCheckedOut(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        return git_branch_is_checked_out(ref) == 1
    }
}
