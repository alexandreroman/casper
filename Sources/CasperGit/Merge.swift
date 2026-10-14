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

/// Thrown when neither the environment (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`) nor the
/// user's Git configuration yields a commit identity: no name or email set, a blank
/// one, an unparsable `GIT_*_DATE`, or a configuration libgit2 cannot read (an
/// `includeIf` condition it does not support, say). `detail` is libgit2's own
/// message, the only thing telling those apart. Casper never invents an identity: a
/// name the user never chose would sit in their history forever. Nothing is written
/// to the repository when this is thrown.
public struct MissingCommitterIdentityError: Error, Equatable, Sendable {
    public let detail: String
    /// The identity variables set in the process environment that the refusal is
    /// blamed on, empty when the configuration is to blame. A set variable shadows
    /// `user.name` / `user.email` even when blank, so `git config` cannot repair what
    /// one of these breaks.
    public let environmentVariables: [String]

    /// Diagnose why `git_signature_default_from_env` fails for `repository` by resolving
    /// the author and the committer again, each on its own. Self-contained: it clears
    /// libgit2's error state itself before each probe.
    ///
    /// A name or email variable is to blame when `git_signature_new` rejects it on its
    /// own: blank, or holding an angle bracket. A date variable is to blame when its own
    /// side fails with no error recorded, which only an unparsable date does; libgit2
    /// exposes no parser to check a date with directly.
    init(diagnosing repository: OpaquePointer) {
        var failures: [SideFailure] = []
        for side in Side.allCases {
            if let failure = Self.failure(of: side, in: repository) {
                failures.append(failure)
            }
        }
        // libgit2 resolves the author first, so its failure is the one libgit2 reports. No
        // side failing means the identity changed since the refused call; say so plainly.
        detail = failures.first?.detail ?? "the identity resolved when retried"

        var blamed: [String] = []
        for variable in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] {
            if let name = Self.environmentValue(variable),
               !Self.signatureAccepts(name: name, email: "placeholder@example.com") {
                blamed.append(variable)
            }
        }
        for variable in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] {
            if let email = Self.environmentValue(variable),
               !Self.signatureAccepts(name: "Placeholder", email: email) {
                blamed.append(variable)
            }
        }
        for failure in failures where failure.unparsableDate {
            blamed.append(failure.side.dateVariable)
        }
        environmentVariables = blamed
    }

    /// One half of a commit's identity. libgit2 resolves each from its own variables.
    private enum Side: CaseIterable {
        case author
        case committer

        var dateVariable: String {
            switch self {
            case .author: "GIT_AUTHOR_DATE"
            case .committer: "GIT_COMMITTER_DATE"
            }
        }
    }

    /// Why resolving one `Side` failed.
    private struct SideFailure {
        let side: Side
        let detail: String
        let unparsableDate: Bool
    }

    /// Resolve `side` alone, as `git_signature_default_from_env` does; nil when it resolves.
    private static func failure(of side: Side, in repository: OpaquePointer) -> SideFailure? {
        var signature: UnsafeMutablePointer<git_signature>?
        defer { git_signature_free(signature) }
        git_error_clear()  // so that a failure recording no error can be told apart
        let code = switch side {
        case .author: git_signature_default_from_env(&signature, nil, repository)
        case .committer: git_signature_default_from_env(nil, &signature, repository)
        }
        guard code != 0 else { return nil }

        let recordedNoError = git_error_last()?.pointee.klass == Int32(GIT_ERROR_NONE.rawValue)
        if recordedNoError {
            return SideFailure(side: side, detail: "unparsable date", unparsableDate: true)
        }
        return SideFailure(side: side, detail: lastErrorMessage(code: code), unparsableDate: false)
    }

    /// `variable`'s value as libgit2 reads it (`getenv`), even when blank; nil when unset.
    private static func environmentValue(_ variable: String) -> String? {
        getenv(variable).map { String(cString: $0) }
    }

    private static func signatureAccepts(name: String, email: String) -> Bool {
        var signature: UnsafeMutablePointer<git_signature>?
        defer { git_signature_free(signature) }
        return git_signature_new(&signature, name, email, 0, 0) == 0
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
    /// The merge commit's author and committer are the user's own, as
    /// `git_signature_default_from_env` derives them: `GIT_AUTHOR_*` and
    /// `GIT_COMMITTER_*` first, then `user.name` / `user.email`.
    ///
    /// Throws `MergeConflictError` when the merge can't be resolved automatically,
    /// and `MissingCommitterIdentityError` when there is a commit to write but
    /// neither the environment nor the user's Git configuration yields a usable
    /// identity to write it as. Nothing is written in either case.
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
        var author: UnsafeMutablePointer<git_signature>?
        var committer: UnsafeMutablePointer<git_signature>?
        defer {  // before the call: free on the throw path too
            git_signature_free(author)
            git_signature_free(committer)
        }
        guard git_signature_default_from_env(&author, &committer, pointer) == 0 else {
            throw MissingCommitterIdentityError(diagnosing: pointer)
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

        var newCommitOid = git_oid()
        let refName = "refs/heads/\(targetBranch)"
        var parents: [OpaquePointer?] = [targetCommit, sourceCommit]
        try gitCheck(parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &newCommitOid, pointer, refName,
                author, committer, "UTF-8", message,
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
}
