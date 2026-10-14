import Clibgit2
import Foundation

/// The result of `Repository.mergeBranchHeadless`.
public enum MergeOutcome: Equatable, Sendable {
    case upToDate
    case merged
}

/// Thrown when a headless merge can't be resolved automatically. Nothing is
/// written to the repository when this is thrown.
public struct MergeConflictError: Error, Equatable, Sendable {}

/// Thrown when the user's Git configuration yields no committer identity
/// (`user.name` / `user.email`). Casper never invents one: a name the user never
/// chose would sit in their history forever. Nothing is written to the
/// repository when this is thrown.
public struct MissingCommitterIdentityError: Error, Equatable, Sendable {}

extension MissingCommitterIdentityError: LocalizedError {
    public var errorDescription: String? {
        "No Git identity is configured. Set user.name and user.email "
            + "(git config --global user.name \"Your Name\"), then try again."
    }
}

extension Repository {
    /// Merge local branch `branchName` into local branch `targetBranch`,
    /// advancing `targetBranch`'s ref. Always writes a 2-parent merge commit
    /// when there is new history to bring in (never fast-forwards) and never
    /// runs `git_checkout` — safe to call even when `targetBranch` is checked
    /// out in another worktree, which simply becomes "behind" until it is
    /// re-checked-out there, exactly as if a teammate had pushed to it.
    ///
    /// Throws `MergeConflictError` when the merge can't be resolved automatically,
    /// and `MissingCommitterIdentityError` when there is a commit to write but the
    /// user's Git configuration names no one to write it as. Nothing is written in
    /// either case.
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
        let baseCode = git_merge_base(&baseOid, pointer, targetOid, sourceOid)
        if baseCode == GIT_ENOTFOUND.rawValue {
            // Two independent histories. Refusing is deliberate for v1: a headless
            // merge must not silently stitch unrelated trees together. The code alone
            // is a missing branch's too, so the message, in `git merge`'s wording, is
            // what tells the two apart. Nothing has been written.
            throw GitError(
                code: GIT_ENOTFOUND.rawValue,
                message: "refusing to merge unrelated histories ('\(branchName)' into '\(targetBranch)')")
        }
        try gitCheck(baseCode)
        if git_oid_equal(&baseOid, sourceOid) != 0 {
            return .upToDate
        }
        // Before the merge writes its tree: a refusal leaves no object behind.
        let signature = try mergeSignature()
        defer { git_signature_free(signature) }

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

        var newCommitOid = git_oid()
        let refName = "refs/heads/\(targetBranch)"
        var parents: [OpaquePointer?] = [targetCommit, sourceCommit]
        try gitCheck(parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &newCommitOid, pointer, refName,
                signature, signature, "UTF-8", message,
                mergeTree, buf.count, buf.baseAddress)
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
        // Guarded: a FORCE checkout mmaps live working-directory files (SIGBUS risk). See SigbusGuard.
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

    /// The merge commit's author and committer: the user's configured identity.
    /// Any failure to derive one — `user.name` or `user.email` unset or blank —
    /// throws `MissingCommitterIdentityError`, as `createInitialCommit` declines.
    private func mergeSignature() throws -> UnsafeMutablePointer<git_signature> {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0, let signature else {
            throw MissingCommitterIdentityError()
        }
        return signature
    }
}
