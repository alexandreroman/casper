import CasperGit
import Foundation

/// A worktree-creation failure expressed in Casper's own vocabulary, so the UI
/// never sees a raw libgit2 code.
struct WorktreeError: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case repositoryNotFound
        case branchAlreadyCheckedOut
        case worktreePathExists
        case mergeConflict
        case fileCopyFailed(String)
        case configInvalid(String)
        case gitFailure(String)
    }

    let reason: Reason
    init(_ reason: Reason) { self.reason = reason }
}

extension WorktreeError: LocalizedError {
    var errorDescription: String? {
        switch reason {
        case .repositoryNotFound:
            return "Repository not found."
        case .branchAlreadyCheckedOut:
            return "That branch is already checked out in another worktree."
        case .worktreePathExists:
            return "The worktree path already exists."
        case .mergeConflict:
            return "The merge could not be completed automatically due to conflicts."
        case .fileCopyFailed(let message):
            return "Failed to copy workspace files: \(message)"
        case .configInvalid(let message):
            return "Invalid .casper.json: \(message)"
        case .gitFailure(let message):
            return "Git error: \(message)"
        }
    }
}

/// The result of creating a worktree: enough to build a `Workspace`.
public struct CreatedWorktree: Equatable, Sendable {
    public let name: String
    public let path: String
    public let branch: String

    public init(name: String, path: String, branch: String) {
        self.name = name
        self.path = path
        self.branch = branch
    }
}

/// Orchestrates `CasperGit` primitives into workspace-creation operations,
/// enforcing Casper's rules and never crashing on git failure.
public enum WorktreeManager {
    /// Open the repository at `repoPath`, translating any open failure into a
    /// `repositoryNotFound` so callers never see a raw libgit2 error.
    private static func openRepo(_ repoPath: String) throws -> Repository {
        do { return try Repository.open(atPath: repoPath) }
        catch { throw WorktreeError(.repositoryNotFound) }
    }

    /// Run `body`, mapping any `GitError` it throws into a `gitFailure`. Every
    /// other error propagates unchanged.
    private static func mapGitError<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as GitError { throw WorktreeError(.gitFailure(error.message)) }
    }

    /// Create a worktree named `name` (on a new branch of the same name, based
    /// on `base` or HEAD) at `worktreePath` for the repository at `repoPath`.
    /// Before any Git mutation, loads `<repoPath>/.casper.json`; a malformed or
    /// unreadable file throws `WorktreeError(.configInvalid)` so nothing is created. After the
    /// git-level worktree is created, copies files matching the config's
    /// `workspace.copyFiles` (or `WorkspaceFileCopier.defaultPatterns` when the
    /// file is absent or does not specify them) from `repoPath` into
    /// `worktreePath`; a copy failure rolls back the worktree and branch so
    /// nothing is left half-created on disk.
    public static func create(
        repoPath: String, name: String, worktreePath: String, base: String?
    ) throws -> CreatedWorktree {
        let repo = try openRepo(repoPath)

        if (try? repo.isBranchCheckedOut(name)) == true {
            throw WorktreeError(.branchAlreadyCheckedOut)
        }
        if FileManager.default.fileExists(atPath: worktreePath) {
            throw WorktreeError(.worktreePathExists)
        }

        // Validate the per-repo config before creating anything, so a malformed
        // file aborts with nothing half-created (no rollback needed here).
        let config: RepoConfig?
        do {
            config = try RepoConfig.load(fromRepoRoot: repoPath)
        } catch let error as RepoConfigError {
            throw WorktreeError(.configInvalid(error.reason))
        }
        // A missing `.casper.json` behaves exactly like one that omits `copyFiles`,
        // so an empty config resolves the default in one place.
        let patterns = (config ?? RepoConfig()).copyFiles(default: WorkspaceFileCopier.defaultPatterns)

        let info = try mapGitError {
            try repo.addWorktree(name: name, atPath: worktreePath, basedOn: base)
        }

        do {
            _ = try WorkspaceFileCopier.copy(
                patterns: patterns, from: repoPath, to: worktreePath)
        } catch {
            try? remove(repoPath: repoPath, name: name, worktreePath: worktreePath)
            try? deleteBranch(repoPath: repoPath, name: name)
            throw WorktreeError(.fileCopyFailed("\(error)"))
        }

        return CreatedWorktree(name: info.name, path: info.path, branch: name)
    }

    /// List worktrees of the repository at `repoPath`.
    public static func list(repoPath: String) throws -> [WorktreeInfo] {
        let repo = try openRepo(repoPath)
        return try mapGitError {
            try repo.worktreeNames().map { try repo.worktreeInfo(name: $0) }
        }
    }

    /// The name git registered for the worktree checked out at `worktreePath`, or
    /// nil when the repository lists no worktree there (or cannot be read).
    ///
    /// Casper's own worktrees are registered under their branch name, so the two are
    /// interchangeable for them — but a worktree created outside Casper and later
    /// adopted into a Space can carry any name, and pruning its admin entry needs the
    /// registered one, not the branch.
    public static func registeredName(repoPath: String, worktreePath: String) -> String? {
        let target = canonicalPath(worktreePath)
        return (try? list(repoPath: repoPath))?
            .first(where: { canonicalPath($0.path) == target })?.name
    }

    /// `path` with symlinks resolved, so paths reported by libgit2 and paths held by
    /// the model compare equal whichever spelling each came from.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Remove the worktree named `name` (working tree at `worktreePath`) from the
    /// repository at `repoPath`, guaranteeing the working-tree directory is gone
    /// from disk.
    ///
    /// Deletes the directory with `forceRemoveDirectory` first — robust against
    /// read-only entries (e.g. a 0555 Go module cache) that defeat libgit2's own
    /// recursive rmdir — then prunes only the libgit2 admin metadata. Doing it in
    /// this order sidesteps `git_worktree_prune`'s "delete admin entry before the
    /// working tree" trap, which silently orphans the directory when the rmdir
    /// fails. Idempotent: an already-removed directory and an already-pruned admin
    /// entry are both no-ops.
    public static func remove(repoPath: String, name: String, worktreePath: String) throws {
        try forceRemoveDirectory(at: worktreePath)
        let repo = try openRepo(repoPath)
        try mapGitError { try repo.pruneWorktreeMetadata(name: name) }
    }

    /// Recursively delete the directory tree at `path`, guaranteeing removal even
    /// when it contains read-only entries. Read-only directories (mode 0555) can't
    /// have their contents unlinked, so owner write+execute is first restored on
    /// the root and every directory beneath it (and write on regular files) before
    /// `FileManager.removeItem` runs. A non-existent path is a no-op success
    /// (idempotent). Uses `Foundation` only.
    public static func forceRemoveDirectory(at path: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }

        restoreOwnerPermissions(under: path, using: fileManager)
        try fileManager.removeItem(atPath: path)
    }

    /// Grant the owner write+execute on `path` and every directory beneath it, and
    /// write on every regular file, so nothing read-only blocks removal. Symlinks
    /// are skipped so a link's target outside the tree is never touched — including
    /// the root itself: `setAttributes` is `chmod` (not `lchmod`) and would follow
    /// a symlinked root out of the tree, so a symlinked root is left untouched for
    /// `removeItem` to simply unlink. The root is typed without resolving its final
    /// link (a regular-file root gets 0600, a real directory 0700).
    /// Best-effort: per-item failures are ignored, since the following
    /// `removeItem` is what surfaces a genuine problem.
    private static func restoreOwnerPermissions(under path: String, using fileManager: FileManager) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let rootURL = URL(fileURLWithPath: path)

        let rootValues = try? rootURL.resourceValues(forKeys: Set(keys))
        if rootValues?.isSymbolicLink == true { return }
        setOwnerWritable(path, isDirectory: rootValues?.isDirectory == true, using: fileManager)

        guard let enumerator = fileManager.enumerator(
            at: rootURL, includingPropertiesForKeys: keys) else { return }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            setOwnerWritable(url.path, isDirectory: values?.isDirectory == true, using: fileManager)
        }
    }

    /// Add owner write (and, for directories, execute) permissions to the item at
    /// `path`, ignoring any failure.
    private static func setOwnerWritable(_ path: String, isDirectory: Bool, using fileManager: FileManager) {
        let mode = isDirectory ? 0o700 : 0o600
        try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    /// Delete the local branch `name` in the repository at `repoPath`. Idempotent.
    public static func deleteBranch(repoPath: String, name: String) throws {
        let repo = try openRepo(repoPath)
        try mapGitError { try repo.deleteBranch(name) }
    }

    /// Merge `branch` into `targetBranch` in the repository at `repoPath`,
    /// writing a merge commit and advancing `targetBranch`. Throws
    /// `WorktreeError(.mergeConflict)` when the merge can't be resolved
    /// automatically — nothing is written to the repository in that case.
    public static func merge(
        repoPath: String, branch: String, into targetBranch: String, message: String
    ) throws -> MergeOutcome {
        let repo = try openRepo(repoPath)
        do {
            return try repo.mergeBranchHeadless(branch, into: targetBranch, message: message)
        } catch is MergeConflictError {
            throw WorktreeError(.mergeConflict)
        } catch let error as GitError {
            throw WorktreeError(.gitFailure(error.message))
        }
    }

    /// Force the working tree at `repoPath` to match its current HEAD commit.
    /// Used to resync a sibling worktree after a headless merge (`merge(...)`)
    /// advanced the branch it has checked out.
    public static func resyncWorkingTree(repoPath: String) throws {
        let repo = try openRepo(repoPath)
        try mapGitError { try repo.forceCheckoutHead() }
    }

    /// Whether the working tree of the repository at `repoPath` is clean.
    public static func isClean(repoPath: String) throws -> Bool {
        let repo = try openRepo(repoPath)
        return try mapGitError { try repo.isClean() }
    }
}
