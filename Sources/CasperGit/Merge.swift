import Clibgit2

/// The result of `Repository.mergeBranchHeadless`.
public enum MergeOutcome: Equatable, Sendable {
    case upToDate
    case merged
}

/// Thrown when a headless merge can't be resolved automatically. Nothing is
/// written to the repository when this is thrown.
public struct MergeConflictError: Error, Equatable, Sendable {
    public init() {}
}

extension Repository {
    /// Merge local branch `branchName` into local branch `targetBranch`,
    /// advancing `targetBranch`'s ref. Always writes a 2-parent merge commit
    /// when there is new history to bring in (never fast-forwards) and never
    /// runs `git_checkout` — safe to call even when `targetBranch` is checked
    /// out in another worktree, which simply becomes "behind" until it is
    /// re-checked-out there, exactly as if a teammate had pushed to it.
    public func mergeBranchHeadless(
        _ branchName: String, into targetBranch: String, message: String
    ) throws -> MergeOutcome {
        let targetCommit = try commit(forBranch: targetBranch)
        defer { git_object_free(targetCommit) }
        let sourceCommit = try commit(forBranch: branchName)
        defer { git_object_free(sourceCommit) }

        let targetOid = git_object_id(targetCommit)
        let sourceOid = git_object_id(sourceCommit)
        var baseOid = git_oid()
        try gitCheck(git_merge_base(&baseOid, pointer, targetOid, sourceOid))
        if git_oid_equal(&baseOid, sourceOid) != 0 {
            return .upToDate
        }

        var mergeOptions = git_merge_options()
        try gitCheck(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var index: OpaquePointer?
        try gitCheck(git_merge_commits(&index, pointer, targetCommit, sourceCommit, &mergeOptions))
        defer { git_index_free(index) }
        let mergeIndex = try requireNonNull(index, "merge index")

        if git_index_has_conflicts(mergeIndex) != 0 {
            throw MergeConflictError()
        }

        var treeOid = git_oid()
        try gitCheck(git_index_write_tree_to(&treeOid, mergeIndex, pointer))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, pointer, &treeOid))
        defer { git_tree_free(tree) }
        let mergeTree = try requireNonNull(tree, "merge tree")

        let signature = try mergeSignature()
        defer { git_signature_free(signature) }

        var newCommitOid = git_oid()
        let refName = "refs/heads/\(targetBranch)"
        var parents: [OpaquePointer?] = [targetCommit, sourceCommit]
        try gitCheck(parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &newCommitOid, pointer, refName,
                signature, signature, "UTF-8", message,
                mergeTree, 2, buf.baseAddress)
        })

        return .merged
    }

    /// Force the working tree and index to match the current HEAD commit,
    /// discarding any difference between them — but never touches HEAD or refs
    /// itself. Used to resync a sibling worktree after `mergeBranchHeadless`
    /// advanced the branch it has checked out (that method never runs
    /// `git_checkout`, by design), once the caller has confirmed it's safe to
    /// discard whatever is currently on disk there (e.g. the worktree is clean).
    public func forceCheckoutHead() throws {
        // A FORCE checkout reads and hashes the existing workdir files before
        // overwriting them, and libgit2 mmaps them to do so; a concurrent
        // truncation can raise SIGBUS mid-hash. Guard it so that fault surfaces as
        // a throw instead of killing the process.
        try SigbusGuard.run { [self] in
        var options = git_checkout_options()
        try gitCheck(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try gitCheck(git_checkout_head(pointer, &options))
        }
    }

    /// Resolve local branch `name` to its tip commit object. Throws `GitError`
    /// (`GIT_ENOTFOUND`) when the branch does not exist.
    private func commit(forBranch name: String) throws -> OpaquePointer {
        var ref: OpaquePointer?
        try gitCheck(git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        var commit: OpaquePointer?
        try gitCheck(git_reference_peel(&commit, ref, GIT_OBJECT_COMMIT))
        return try requireNonNull(commit, "commit")
    }

    /// A signature for the merge commit: the repo's configured user if set,
    /// else a fixed fallback (a headless merge has no interactive user).
    private func mergeSignature() throws -> UnsafeMutablePointer<git_signature> {
        var signature: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&signature, pointer) == 0, let signature {
            return signature
        }
        var fallback: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&fallback, "Casper", "casper@localhost"))
        return try requireNonNull(fallback, "signature")
    }
}
