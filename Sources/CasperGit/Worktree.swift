import Clibgit2
import Foundation

/// Value description of a git worktree.
public struct WorktreeInfo: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isLocked: Bool

    public init(name: String, path: String, isLocked: Bool) {
        self.name = name
        self.path = path
        self.isLocked = isLocked
    }
}

extension Repository {
    /// Create a worktree named `name` at `path`, checked out to a new branch
    /// (also named `name`) based on `basedOn` (a branch/tag/commit-ish) or HEAD.
    public func addWorktree(
        name: String, atPath path: String, basedOn: String?
    ) throws -> WorktreeInfo {
        // Resolve the base commit.
        var baseObject: OpaquePointer?
        if let basedOn {
            try gitCheck(git_revparse_single(&baseObject, pointer, basedOn))
        } else {
            try gitCheck(git_revparse_single(&baseObject, pointer, "HEAD"))
        }
        defer { git_object_free(baseObject) }
        var commit: OpaquePointer?
        try gitCheck(git_object_peel(&commit, baseObject, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }

        // Create the branch at that commit.
        var branchRef: OpaquePointer?
        try gitCheck(git_branch_create(&branchRef, pointer, name, commit, 0))
        defer { git_reference_free(branchRef) }

        // Add the worktree checked out to the new branch.
        var options = git_worktree_add_options()
        git_worktree_add_options_init(
            &options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))
        options.ref = branchRef

        var worktree: OpaquePointer?
        try gitCheck(git_worktree_add(&worktree, pointer, name, path, &options))
        defer { git_worktree_free(worktree) }

        return worktreeInfo(fromPointer: worktree!, name: name)
    }

    /// Build a `WorktreeInfo` from an open `git_worktree*`.
    func worktreeInfo(fromPointer worktree: OpaquePointer, name: String) -> WorktreeInfo {
        let path = String(cString: git_worktree_path(worktree))
        var reason = git_buf()
        let locked = git_worktree_is_locked(&reason, worktree) > 0
        git_buf_dispose(&reason)
        return WorktreeInfo(name: name, path: path, isLocked: locked)
    }
}
