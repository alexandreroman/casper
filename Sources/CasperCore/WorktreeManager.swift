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
    /// Create a worktree named `name` (on a new branch of the same name, based
    /// on `base` or HEAD) at `worktreePath` for the repository at `repoPath`.
    public static func create(
        repoPath: String, name: String, worktreePath: String, base: String?
    ) throws -> CreatedWorktree {
        let repo: Repository
        do {
            repo = try Repository.open(atPath: repoPath)
        } catch {
            throw WorktreeError(.repositoryNotFound)
        }

        if (try? repo.isBranchCheckedOut(name)) == true {
            throw WorktreeError(.branchAlreadyCheckedOut)
        }
        if FileManager.default.fileExists(atPath: worktreePath) {
            throw WorktreeError(.worktreePathExists)
        }

        let info: WorktreeInfo
        do {
            info = try repo.addWorktree(
                name: name, atPath: worktreePath, basedOn: base)
        } catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }

        return CreatedWorktree(
            name: info.name, path: info.path, branch: name,
            repoPath: repo.workdirPath ?? repoPath)
    }
}
