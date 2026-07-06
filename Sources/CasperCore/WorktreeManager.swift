import CasperGit
import Foundation

/// A worktree-creation failure expressed in Casper's own vocabulary, so the UI
/// never sees a raw libgit2 code.
public struct WorktreeError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case repositoryNotFound
        case branchAlreadyCheckedOut
        case worktreePathExists
        case gitFailure(String)
    }

    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

/// The result of creating a worktree: enough to build a `Workspace`.
public struct CreatedWorktree: Equatable, Sendable {
    public let name: String
    public let path: String
    public let branch: String
    public let repoPath: String

    public init(name: String, path: String, branch: String, repoPath: String) {
        self.name = name
        self.path = path
        self.branch = branch
        self.repoPath = repoPath
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

        let info = try mapGitError {
            try repo.addWorktree(name: name, atPath: worktreePath, basedOn: base)
        }

        return CreatedWorktree(
            name: info.name, path: info.path, branch: name,
            repoPath: repo.workdirPath ?? repoPath)
    }

    /// List worktrees of the repository at `repoPath`.
    public static func list(repoPath: String) throws -> [WorktreeInfo] {
        let repo = try openRepo(repoPath)
        return try mapGitError {
            try repo.worktreeNames().map { try repo.worktreeInfo(name: $0) }
        }
    }

    /// Remove the worktree named `name` from the repository at `repoPath`.
    public static func remove(repoPath: String, name: String) throws {
        let repo = try openRepo(repoPath)
        try mapGitError { try repo.pruneWorktree(name: name) }
    }

    /// Delete the local branch `name` in the repository at `repoPath`. Idempotent.
    public static func deleteBranch(repoPath: String, name: String) throws {
        let repo = try openRepo(repoPath)
        try mapGitError { try repo.deleteBranch(name) }
    }

    /// Whether the working tree of the repository at `repoPath` is clean.
    public static func isClean(repoPath: String) throws -> Bool {
        let repo = try openRepo(repoPath)
        return try mapGitError { try repo.isClean() }
    }
}
