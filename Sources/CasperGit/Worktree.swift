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
        try gitCheck(git_revparse_single(&baseObject, pointer, basedOn ?? "HEAD"))
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
        try gitCheck(git_worktree_add_options_init(
            &options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION)))
        options.ref = branchRef

        var worktree: OpaquePointer?
        do {
            try gitCheck(git_worktree_add(&worktree, pointer, name, path, &options))
            defer { git_worktree_free(worktree) }
            let handle = try requireNonNull(worktree, "worktree")
            return try worktreeInfo(fromPointer: handle, name: name)
        } catch {
            // Roll back so retrying the same name is idempotent instead of
            // failing with GIT_EEXISTS. If `git_worktree_add` already created the
            // worktree before a later step threw, prune it first — otherwise the
            // working tree is orphaned — then delete the branch created above.
            // The `defer`s still free the handles; this clears the on-disk
            // worktree and the refdb branch. `pruneWorktree` re-looks-up by name,
            // which is safe now that the handle above has been freed.
            if worktree != nil {
                try? pruneWorktree(name: name)
            }
            git_branch_delete(branchRef)
            throw error
        }
    }

    /// Build a `WorktreeInfo` from an open `git_worktree*`.
    func worktreeInfo(fromPointer worktree: OpaquePointer, name: String) throws -> WorktreeInfo {
        let cPath = try requireNonNull(git_worktree_path(worktree), "worktree path")
        let path = String(cString: cPath)
        var reason = git_buf()
        let rc = git_worktree_is_locked(&reason, worktree)
        git_buf_dispose(&reason)
        if rc < 0 { try gitCheck(rc) }
        return WorktreeInfo(name: name, path: path, isLocked: rc > 0)
    }

    /// Names of all worktrees linked to this repository.
    public func worktreeNames() throws -> [String] {
        try gitStringArray { array in
            try gitCheck(git_worktree_list(&array, pointer))
        }
    }

    /// Look up a single worktree by name. Throws a `GitError` (`GIT_ENOTFOUND`)
    /// when no worktree with that name is registered.
    public func worktreeInfo(name: String) throws -> WorktreeInfo {
        var worktree: OpaquePointer?
        let code = git_worktree_lookup(&worktree, pointer, name)
        defer { git_worktree_free(worktree) }
        if code == GIT_ENOTFOUND.rawValue {
            throw GitError(code: GIT_ENOTFOUND.rawValue, message: "worktree not found: \(name)")
        }
        try gitCheck(code)
        let handle = try requireNonNull(worktree, "worktree")
        return try worktreeInfo(fromPointer: handle, name: name)
    }

    /// Prune the worktree named `name`, removing both its admin entry and its
    /// working-tree directory.
    ///
    /// Does not set `GIT_WORKTREE_PRUNE_LOCKED`, so a locked worktree is not
    /// pruned. Casper never locks its worktrees.
    public func pruneWorktree(name: String) throws {
        var worktree: OpaquePointer?
        try gitCheck(git_worktree_lookup(&worktree, pointer, name))
        defer { git_worktree_free(worktree) }

        var options = git_worktree_prune_options()
        try gitCheck(git_worktree_prune_options_init(
            &options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))
        options.flags =
            GIT_WORKTREE_PRUNE_VALID.rawValue
            | GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue

        try gitCheck(git_worktree_prune(worktree, &options))
    }
}
