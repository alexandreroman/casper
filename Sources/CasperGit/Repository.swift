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

    /// Working-tree status entries (index + worktree), untracked files included.
    public func status() throws -> [FileStatus] {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags =
            GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

        var list: OpaquePointer?
        try gitCheck(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }

        let count = git_status_list_entrycount(list)
        var result: [FileStatus] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let entry = git_status_byindex(list, index) else { continue }
            let bits = entry.pointee.status
            let delta = entry.pointee.index_to_workdir ?? entry.pointee.head_to_index
            let path: String
            if let delta, let newPath = delta.pointee.new_file.path {
                path = String(cString: newPath)
            } else {
                continue
            }
            result.append(FileStatus(
                path: path,
                isNew: bits.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0,
                isModified: bits.rawValue
                    & (GIT_STATUS_INDEX_MODIFIED.rawValue
                       | GIT_STATUS_WT_MODIFIED.rawValue) != 0,
                isDeleted: bits.rawValue
                    & (GIT_STATUS_INDEX_DELETED.rawValue
                       | GIT_STATUS_WT_DELETED.rawValue) != 0,
                isUntracked: bits.rawValue & GIT_STATUS_WT_NEW.rawValue != 0))
        }
        return result
    }

    /// Whether the working tree and index are clean (no changes, no untracked).
    public func isClean() throws -> Bool {
        try status().isEmpty
    }
}

/// Per-path working-tree status, reduced to the flags Casper needs.
public struct FileStatus: Equatable, Sendable {
    public let path: String
    public let isNew: Bool
    public let isModified: Bool
    public let isDeleted: Bool
    public let isUntracked: Bool

    public init(
        path: String, isNew: Bool, isModified: Bool,
        isDeleted: Bool, isUntracked: Bool
    ) {
        self.path = path
        self.isNew = isNew
        self.isModified = isModified
        self.isDeleted = isDeleted
        self.isUntracked = isUntracked
    }
}
