import Foundation

/// A repository's `.casper.json`, read from the repo root when a workspace is
/// created. The file is grouped by domain so future sections have a home; only
/// `workspace.copyPatterns` is read today. Unknown keys are ignored, so a file
/// that already carries other sections still decodes.
public struct RepoConfig: Codable, Equatable, Sendable {
    /// Workspace-scoped preferences.
    public struct Workspace: Codable, Equatable, Sendable {
        /// File-name patterns (matched via `fnmatch(3)`) copied into a new
        /// worktree. `nil` means "unspecified" (use the caller's defaults); an
        /// explicit empty array means "copy nothing".
        public var copyPatterns: [String]?

        public init(copyPatterns: [String]? = nil) {
            self.copyPatterns = copyPatterns
        }
    }

    public var workspace: Workspace?

    public init(workspace: Workspace? = nil) {
        self.workspace = workspace
    }

    /// The effective copy patterns: the file's list when present, else `defaults`.
    /// An explicit empty list is returned as empty (copy nothing).
    public func copyPatterns(default defaults: [String]) -> [String] {
        workspace?.copyPatterns ?? defaults
    }

    /// Load `<repoRoot>/.casper.json`. Returns nil when the file does not exist.
    /// Throws `RepoConfigError` when the file exists but cannot be read or decoded.
    public static func load(fromRepoRoot repoRoot: String) throws -> RepoConfig? {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(".casper.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RepoConfigError(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(RepoConfig.self, from: data)
        } catch {
            throw RepoConfigError(path: url.path, reason: "\(error)")
        }
    }
}

/// A `.casper.json` that exists but cannot be read or decoded.
public struct RepoConfigError: Error, Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}
