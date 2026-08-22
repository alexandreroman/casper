import Foundation

/// A repository's `.casper.json`, read from the repo root when a workspace is
/// created. The file is grouped by domain so future sections have a home; the
/// `workspace` section is the only one read today — its `copyFiles` patterns
/// and its named `scripts` (the `setup`/`teardown` lifecycle hooks plus the
/// user-invocable commands). Unknown keys are ignored, so a file that already
/// carries other sections still decodes.
public struct RepoConfig: Codable, Equatable, Sendable {
    /// Workspace-scoped preferences.
    public struct Workspace: Codable, Equatable, Sendable {
        /// File-name patterns (matched via `fnmatch(3)`) copied into a new
        /// worktree. `nil` means "unspecified" (use the caller's defaults); an
        /// explicit empty array means "copy nothing".
        public var copyFiles: [String]?

        /// Named shell scripts attached to the workspace. Reserved names `setup`
        /// and `teardown` are lifecycle hooks; every other name is a user-invocable
        /// command. An empty command string is treated as no script.
        public var scripts: [String: String]?

        public init(copyFiles: [String]? = nil, scripts: [String: String]? = nil) {
            self.copyFiles = copyFiles
            self.scripts = scripts
        }
    }

    public var workspace: Workspace?

    public init(workspace: Workspace? = nil) {
        self.workspace = workspace
    }

    /// The effective list of files to copy: the file's list when present, else
    /// `defaults`. An explicit empty list is returned as empty (copy nothing).
    public func copyFiles(default defaults: [String]) -> [String] {
        workspace?.copyFiles ?? defaults
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
            throw RepoConfigError(path: url.path, reason: readableReason(for: error))
        }
        do {
            return try JSONDecoder().decode(RepoConfig.self, from: data)
        } catch {
            throw RepoConfigError(path: url.path, reason: readableReason(for: error))
        }
    }

    /// A concise, user-facing reason for a load failure. `DecodingError`'s default
    /// string interpolation dumps its full internal structure; extract just the
    /// human-readable description (and the offending key path when available)
    /// instead. Non-decoding errors already have a clean `localizedDescription`.
    private static func readableReason(for error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .dataCorrupted(let context):
            return context.debugDescription
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)': \(context.debugDescription)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
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

/// The outcome of resolving a `casper run <name>` request.
public enum RunResolution: Equatable, Sendable {
    /// The shell command to run.
    case command(String)
    /// A user-facing reason the request was refused (reserved or unknown name).
    case denied(String)
}

/// A user-invocable named command from `workspace.scripts` (a non-reserved key).
public struct RepoNamedCommand: Equatable, Sendable {
    public let name: String
    public let command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

extension RepoNamedCommand {
    /// A human-readable label: the script name with `-`/`_` turned into spaces
    /// and each word capitalized. E.g. `build-app` → `Build App`, `run` → `Run`.
    public var displayName: String {
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? name : words.joined(separator: " ")
    }
}

/// Reserved `workspace.scripts` keys that are lifecycle hooks rather than
/// user-invocable named commands.
public enum RepoScripts {
    public static let reservedNames: Set<String> = ["setup", "teardown"]
}

extension RepoConfig {
    /// The `setup` lifecycle hook command, or nil when absent or empty.
    public func setupScript() -> String? { nonEmptyScript(named: "setup") }

    /// The `teardown` lifecycle hook command, or nil when absent or empty.
    public func teardownScript() -> String? { nonEmptyScript(named: "teardown") }

    /// A user-invocable named command by name, or nil when the name is reserved,
    /// absent, or maps to an empty command.
    public func namedCommand(_ name: String) -> String? {
        guard !RepoScripts.reservedNames.contains(name) else { return nil }
        return nonEmptyScript(named: name)
    }

    /// All user-invocable named commands (non-reserved, non-empty), sorted by name.
    public func namedCommands() -> [RepoNamedCommand] {
        (workspace?.scripts ?? [:])
            .filter { !RepoScripts.reservedNames.contains($0.key) && !$0.value.isEmpty }
            .map { RepoNamedCommand(name: $0.key, command: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Resolve a `casper run <name>` request to a command, or a user-facing reason
    /// why it can't run. Reserved lifecycle names are refused; an unknown name
    /// lists the available named commands.
    public func resolveRunCommand(_ name: String) -> RunResolution {
        if RepoScripts.reservedNames.contains(name) {
            return .denied("'\(name)' is a reserved lifecycle hook, not a runnable command")
        }
        if let command = namedCommand(name) { return .command(command) }
        let available = namedCommands().map(\.name)
        let hint = available.isEmpty
            ? "no named commands defined in .casper.json"
            : "available commands: \(available.joined(separator: ", "))"
        return .denied("no command '\(name)' (\(hint))")
    }

    private func nonEmptyScript(named name: String) -> String? {
        guard let command = workspace?.scripts?[name], !command.isEmpty else { return nil }
        return command
    }
}
