import Foundation

// The I/O half of the Casper agent-integration detection.
//
// `AgentIntegration.swift` owns the policy — the agent catalogue, the status
// vocabulary, the version comparison and one pure parser per agent. This file adds
// the only thing those parsers cannot do for themselves: find the evidence. It
// locates each agent's CLI, reads the files and lists the directories every agent
// leaves behind, and feeds the bytes to the matching parser.
//
// Every side effect goes through an injectable `Environment`, so the whole
// resolution can be exercised without a real home directory, a real install or a
// spawned shell. What is left here is deliberately thin: path construction, the
// order in which evidence is consulted, and the few judgement calls that only make
// sense once real files are involved (an unreadable version is not a stale
// install; a disabled plugin is an absent one).

/// Answers "is the Casper integration installed, and is it current?" for each
/// coding agent, by probing the user's machine.
///
/// The probe is global — one answer per agent for the whole app, not per
/// workspace — and cheap enough to re-run: `LoginShellPath` caches the expensive
/// part (the shell `PATH` probe) for the lifetime of the process.
///
/// **Never call this from the main actor on a cold process.** `statuses()` gates
/// each agent on its CLI, so the first call warms `LoginShellPath`: one shell
/// `PATH` probe — up to three spawns, ~0.5 s on a real machine with Homebrew,
/// nvm and friends in the profile — shared by all three commands, followed by the
/// probe's own file reads and directory listings. On the main actor that is a
/// frozen UI for the whole duration. Run it off the main actor and hand the
/// result back. Subsequent calls are cached and effectively free, but nothing
/// may depend on the cache being warm.
public struct AgentIntegrationProbe: Sendable {

    /// Every filesystem and PATH access the probe makes, injectable so tests can
    /// drive all of it from in-memory fixtures.
    public struct Environment: Sendable {
        /// Absolute path of a command, or nil when the user does not have it.
        public var executablePath: @Sendable (String) -> String?
        /// Contents of a file, or nil when it is absent or unreadable.
        public var fileContents: @Sendable (String) -> Data?
        /// Names of a directory's entries, or `[]` when it is absent or unreadable.
        public var directoryEntries: @Sendable (String) -> [String]
        /// Absolute path of the user's home directory; every probed path hangs off it.
        public var homeDirectory: String

        public init(
            executablePath: @escaping @Sendable (String) -> String?,
            fileContents: @escaping @Sendable (String) -> Data?,
            directoryEntries: @escaping @Sendable (String) -> [String],
            homeDirectory: String
        ) {
            self.executablePath = executablePath
            self.fileContents = fileContents
            self.directoryEntries = directoryEntries
            self.homeDirectory = homeDirectory
        }

        /// The real machine.
        ///
        /// `executablePath` resolves through `LoginShellPath`, and that is **not**
        /// an over-complication to simplify away: Casper is a GUI app launched from
        /// Finder or the Dock, so its own `ProcessInfo.processInfo.environment["PATH"]`
        /// is the bare launchd default — no Homebrew, no nvm, no `~/.local/bin`.
        /// Probing against the process `PATH` would report every agent as
        /// `.notInstalled` for most users, silently disabling the whole feature for
        /// exactly the people who have the agents installed.
        ///
        /// Reads degrade to nil/`[]` instead of throwing: a probe runs against paths
        /// owned by other tools, so a missing file, a directory where a file was
        /// expected, or a permission-denied home are all normal answers, never
        /// errors worth propagating.
        public static let live = Environment(
            executablePath: { LoginShellPath.resolve($0) },
            fileContents: { path in try? Data(contentsOf: URL(fileURLWithPath: path)) },
            directoryEntries: { path in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] },
            homeDirectory: NSHomeDirectory())
    }

    /// The plugin's own directory name inside a Codex marketplace cache. Derived
    /// from the plugin id (`casper@casper` ⇒ `casper`) so the two cannot
    /// drift apart.
    private static let codexPluginDirectoryName = String(AgentIntegration.pluginID.prefix { $0 != "@" })

    private let environment: Environment

    public init(environment: Environment = .live) {
        self.environment = environment
    }

    /// The status of every agent Casper knows about.
    public func statuses() -> [CodingAgent: AgentIntegrationStatus] {
        var result: [CodingAgent: AgentIntegrationStatus] = [:]
        for agent in CodingAgent.allCases {
            result[agent] = status(for: agent)
        }
        return result
    }

    /// The status of one agent.
    ///
    /// The CLI gate comes first for every agent and short-circuits everything else:
    /// a user who does not have the agent gets no reminder, and Casper reads not a
    /// single file on their disk to work that out.
    public func status(for agent: CodingAgent) -> AgentIntegrationStatus {
        guard environment.executablePath(agent.executableName) != nil else { return .notInstalled }

        switch agent {
        case .claudeCode: return claudeCodeStatus()
        case .codex: return codexStatus()
        case .opencode: return opencodeStatus()
        }
    }

    // MARK: - Claude Code

    /// Claude Code records every installed plugin, with its version, in one
    /// registry file, and whether the user has switched it off in another.
    ///
    /// The **registry key is the authority** here, and a plugin cache path must never
    /// stand in for it. The current and legacy ids differ only in the case of their
    /// marketplace (`casper@casper` vs `casper@Casper`), so their cache directories —
    /// `~/.claude/plugins/cache/casper/` and `~/.claude/plugins/cache/Casper/` — are
    /// the *same directory* on a case-insensitive volume, which is the default for
    /// APFS. Deriving anything from `installPath` would therefore read a current
    /// install as legacy, or the reverse, depending on which install wrote the
    /// directory first. Only the registry key and the record's `version` field are
    /// read, and both come straight from the JSON. (Codex is a different agent with a
    /// different layout, and its cache path legitimately does carry the version.)
    private func claudeCodeStatus() -> AgentIntegrationStatus {
        guard let registry = environment.fileContents(homePath(".claude/plugins/installed_plugins.json")),
              let registration = AgentIntegration.parseClaudeRegistry(registry)
        else {
            return .missing
        }

        // Installation and enablement are separate records: a plugin the user has
        // disabled is still registered, but none of its hooks fire. Reporting
        // `.installed` there would tell the user the integration is fine while
        // nothing happens, so a disabled install is `.missing` — the same rule the
        // Codex branch applies to its own disabled flag. An absent settings file
        // means enabled, so it costs nothing to read.
        if let settings = environment.fileContents(homePath(".claude/settings.json")),
           !AgentIntegration.parseClaudeEnabled(settings) {
            return .missing
        }

        // A registration under the legacy id is outdated *whatever version it
        // carries*, so this deliberately bypasses the version comparison. The
        // version says how new the install is; the id says which marketplace it came
        // from, and a pre-rename marketplace is the thing the user has to move off.
        // Leaning on `0.1.0 < requiredPluginVersion` happening to be true today
        // would make the next version bump silently stop reporting these users.
        if registration.usesLegacyPluginID {
            return .outdated(installed: registration.version)
        }
        return status(forInstalledVersion: registration.version)
    }

    // MARK: - opencode

    /// opencode has two independent install shapes, and either one counts: a plugin
    /// file dropped in the plugin directory, or an entry in the config's `plugin`
    /// array (which points at an npm package opencode fetches itself).
    private func opencodeStatus() -> AgentIntegrationStatus {
        let pluginFile = installedOpencodePluginFile()
        guard pluginFile != nil || opencodeConfigRegistersPlugin() else { return .missing }

        // The version only exists inside a local plugin file. A config-only install
        // has none to read, and a plugin file predating the version constant (or
        // simply unreadable) has none either. All three are "installed, version
        // unknown" — reported as `.installed`, never `.outdated`, because an
        // unreadable version is not evidence of a stale install and a false "update
        // your plugin" nag costs more trust than a missed one.
        guard let pluginFile,
              let source = environment.fileContents(pluginFile),
              let version = AgentIntegration.parseOpencodeVersion(String(decoding: source, as: UTF8.self))
        else {
            return .installed
        }
        return status(forInstalledVersion: version)
    }

    /// Path of an installed opencode plugin file, or nil when none is present.
    /// Both directory spellings are valid to opencode's loader, so both are checked.
    private func installedOpencodePluginFile() -> String? {
        for directory in AgentIntegration.opencodePluginDirectories {
            let directoryPath = homePath(directory)
            guard environment.directoryEntries(directoryPath).contains(AgentIntegration.opencodePluginFileName) else {
                continue
            }
            return joinPath(directoryPath, AgentIntegration.opencodePluginFileName)
        }
        return nil
    }

    /// Whether either spelling of the opencode config registers the Casper plugin.
    /// The `.jsonc` extension is the honest one — the format is JSONC under both
    /// names — but `.json` is what opencode writes, so both occur in the wild.
    private func opencodeConfigRegistersPlugin() -> Bool {
        for fileName in ["opencode.json", "opencode.jsonc"] {
            guard let data = environment.fileContents(homePath(".config/opencode/\(fileName)")) else { continue }
            if AgentIntegration.parseOpencodeConfig(String(decoding: data, as: UTF8.self)) { return true }
        }
        return false
    }

    // MARK: - Codex

    /// Codex keeps installs in a cache tree whose *path* carries the version, and
    /// records disabled plugins in its config.
    private func codexStatus() -> AgentIntegrationStatus {
        guard let version = installedCodexPluginVersion() else { return .missing }

        // A plugin the user has switched off is functionally absent: its hooks never
        // run. Reporting `.installed` there would be actively unhelpful — the user
        // would be told the integration is fine while nothing happens — so a
        // disabled install is reported as `.missing`, which is what the reminder is
        // for.
        if let config = environment.fileContents(homePath(".codex/config.toml")),
           AgentIntegration.parseCodexDisabled(String(decoding: config, as: UTF8.self)) {
            return .missing
        }
        return status(forInstalledVersion: version)
    }

    /// Walks `~/.codex/plugins/cache/<marketplace>/casper/<version>/` and returns the
    /// version directory name, or nil when no install is there.
    ///
    /// The marketplace level is enumerated rather than assumed: the same plugin can
    /// be installed from more than one marketplace, and none of the names are
    /// Casper's to predict. Every marketplace's version directories are gathered
    /// before a single winner is picked, because `contentsOfDirectory` returns them
    /// in no defined order: stopping at the first marketplace that holds the plugin
    /// would report an arbitrary one of several installs, and a user who installed
    /// 0.1.0 from one marketplace and 0.2.0 from another would get an "outdated" nag
    /// or not depending on enumeration order. No manifest file is read on purpose — the plugin
    /// repository ships only `.claude-plugin/plugin.json` and relies on Codex's
    /// discovery order falling through to it, so probing by manifest file name would
    /// match nothing.
    ///
    /// NOTE: this cache layout comes from Codex's published documentation and has
    /// **not** been verified against a real install — none was available on either
    /// the app or the plugin side. Whoever first gets a real Codex should confirm it
    /// (`codex plugin add`, then `codex plugin list --json` as a cross-check).
    private func installedCodexPluginVersion() -> String? {
        let cacheRoot = homePath(".codex/plugins/cache")
        var versionDirectoryNames: [String] = []
        for marketplace in environment.directoryEntries(cacheRoot) {
            let marketplacePath = joinPath(cacheRoot, marketplace)
            guard environment.directoryEntries(marketplacePath).contains(Self.codexPluginDirectoryName) else {
                continue
            }
            let pluginPath = joinPath(marketplacePath, Self.codexPluginDirectoryName)
            versionDirectoryNames.append(contentsOf: environment.directoryEntries(pluginPath))
        }
        return AgentIntegration.parseCodexCacheEntries(versionDirectoryNames)
    }

    // MARK: - Shared helpers

    /// The one place a found version turns into a status, so every agent applies the
    /// same `installed < required` rule.
    private func status(forInstalledVersion version: String) -> AgentIntegrationStatus {
        let outdated = AgentIntegration.isOutdated(
            installed: version,
            required: AgentIntegration.requiredPluginVersion)
        return outdated ? .outdated(installed: version) : .installed
    }

    private func homePath(_ relativePath: String) -> String {
        joinPath(environment.homeDirectory, relativePath)
    }

    private func joinPath(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }
}
