import Foundation
import XCTest
@testable import CasperCore

/// Every test here drives `AgentIntegrationProbe` through a fully stubbed
/// `Environment`: the suite never touches the real filesystem and never spawns a
/// login shell, so the results depend on the fixtures alone and not on whichever
/// agents the developer happens to have installed.
final class AgentIntegrationProbeTests: XCTestCase {

    // MARK: - Fixtures

    private static let home = "/stub-home"

    private static let claudeRegistryPath = "\(home)/.claude/plugins/installed_plugins.json"
    private static let claudeSettingsPath = "\(home)/.claude/settings.json"
    private static let opencodePluginPath = "\(home)/.config/opencode/plugin"
    private static let opencodePluginsPath = "\(home)/.config/opencode/plugins"
    private static let opencodeConfigPath = "\(home)/.config/opencode/opencode.json"
    private static let opencodeConfigJSONCPath = "\(home)/.config/opencode/opencode.jsonc"
    private static let codexCachePath = "\(home)/.codex/plugins/cache"
    private static let codexMarketplacePath = "\(codexCachePath)/casper"
    private static let codexPluginPath = "\(codexMarketplacePath)/casper"
    private static let codexConfigPath = "\(home)/.codex/config.toml"

    /// A version guaranteed to be below whatever `requiredPluginVersion` says, so
    /// bumping that constant never breaks these tests.
    private static let oldVersion = "0.0.1"
    private static let currentVersion = AgentIntegration.requiredPluginVersion

    private static func claudeRegistry(version: String) -> String {
        """
        {"version": 2,
         "plugins": {"\(AgentIntegration.pluginID)": [
           {"scope": "user", "installPath": "/somewhere", "version": "\(version)"}]}}
        """
    }

    /// The pre-rename registry shape, `installPath` and `gitCommitSha` included, as
    /// found on a real machine that installed before the marketplace was renamed.
    private static func legacyClaudeRegistry(version: String) -> String {
        """
        {"version": 2,
         "plugins": {"\(AgentIntegration.legacyPluginID)": [
           {"scope": "user",
            "installPath": "/Users/alex/.claude/plugins/cache/Casper/casper/\(version)",
            "version": "\(version)",
            "installedAt": "2026-07-07T13:04:49.792Z",
            "lastUpdated": "2026-07-07T13:04:49.792Z",
            "gitCommitSha": "17fd..."}]}}
        """
    }

    private static func opencodePlugin(version: String) -> String {
        """
        export const CASPER_PLUGIN_VERSION = "\(version)"
        export const CasperPlugin = async () => ({})
        """
    }

    private static let opencodeConfig = #"{"plugin": ["casper-skills"]}"#

    private static let codexConfigDisabled = """
        [plugins."\(AgentIntegration.pluginID)"]
        enabled = false
        """

    /// A `config.toml` whose `[hooks.state]` records the plugin's hooks as approved,
    /// in the shape Codex writes: one table per hook, plus an unrelated hook keyed by
    /// absolute path.
    private static let codexConfigHooksTrusted = """
        [hooks.state]

        [hooks.state."\(AgentIntegration.pluginID):hooks/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:63ef580c6830c4c80d21164707f0c0afe2daf03eeb2238cb3ee154"
        enabled = true

        [hooks.state."/stub-home/.codex/hooks.json:stop:0:0"]
        trusted_hash = "sha256:86cfa1963b6b0f3d2a1c8e4d5b6a7f8091a2b3c4d5e6f708192a3b"
        """

    // MARK: - Stub environment

    /// Records every path the probe read or listed. `@unchecked Sendable` because
    /// the recorded paths are only ever touched under `lock` — the same discipline
    /// `LoginShellPath`'s own storage uses.
    private final class AccessRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        var accessedPaths: [String] { lock.withLock { paths } }

        func record(_ path: String) {
            lock.withLock { paths.append(path) }
        }
    }

    private func makeEnvironment(
        executables: Set<String>,
        files: [String: String] = [:],
        directories: [String: [String]] = [:],
        recorder: AccessRecorder = AccessRecorder()
    ) -> AgentIntegrationProbe.Environment {
        AgentIntegrationProbe.Environment(
            executablePath: { executables.contains($0) ? "/opt/stub/bin/\($0)" : nil },
            fileContents: { path in
                recorder.record(path)
                return files[path].map { Data($0.utf8) }
            },
            directoryEntries: { path in
                recorder.record(path)
                return directories[path] ?? []
            },
            homeDirectory: Self.home)
    }

    /// Fixtures describing a complete, current install of all three integrations.
    /// Tests then subtract from these rather than rebuilding them.
    private var fullyInstalledFiles: [String: String] {
        [
            Self.claudeRegistryPath: Self.claudeRegistry(version: Self.currentVersion),
            "\(Self.opencodePluginPath)/casper.js": Self.opencodePlugin(version: Self.currentVersion),
            // Codex's half of "complete" includes the hook approval: without it the
            // install is on disk but inert.
            Self.codexConfigPath: Self.codexConfigHooksTrusted,
        ]
    }

    private var fullyInstalledDirectories: [String: [String]] {
        [
            Self.opencodePluginPath: ["casper.js"],
            Self.codexCachePath: ["casper"],
            Self.codexMarketplacePath: ["casper"],
            Self.codexPluginPath: [Self.currentVersion],
        ]
    }

    // MARK: - The CLI gate

    func testAbsentCLIReportsNotInstalledWithoutReadingAnything() {
        // Everything is installed on disk; the user simply does not have the CLIs.
        for agent in CodingAgent.allCases {
            let recorder = AccessRecorder()
            let probe = AgentIntegrationProbe(
                environment: makeEnvironment(
                    executables: [],
                    files: fullyInstalledFiles,
                    directories: fullyInstalledDirectories,
                    recorder: recorder))

            XCTAssertEqual(probe.status(for: agent), .notInstalled, "\(agent)")
            // An agent the user does not have must cost zero disk access.
            XCTAssertEqual(recorder.accessedPaths, [], "\(agent) probed the disk")
        }
    }

    // MARK: - Claude Code

    func testClaudeCodeMissingWhenRegistryAbsent() {
        let probe = AgentIntegrationProbe(environment: makeEnvironment(executables: ["claude"]))
        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
    }

    func testClaudeCodeMissingWhenRegistryDoesNotListThePlugin() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [Self.claudeRegistryPath: #"{"version": 2, "plugins": {"other@market": []}}"#]))
        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
    }

    func testClaudeCodeInstalledWhenCurrent() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(executables: ["claude"], files: fullyInstalledFiles))
        XCTAssertEqual(probe.status(for: .claudeCode), .installed)
    }

    func testClaudeCodeOutdatedCarriesTheInstalledVersion() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [Self.claudeRegistryPath: Self.claudeRegistry(version: Self.oldVersion)]))
        XCTAssertEqual(probe.status(for: .claudeCode), .outdated(installed: Self.oldVersion))
    }

    func testClaudeCodeLegacyPluginIDReportsOutdated() {
        // The state every pre-rename user is in the moment the rename ships: the
        // integration is installed and working, just from the old marketplace. It
        // must send them to update instructions, never to install instructions.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [Self.claudeRegistryPath: Self.legacyClaudeRegistry(version: "0.1.0")]))
        XCTAssertEqual(probe.status(for: .claudeCode), .outdated(installed: "0.1.0"))
    }

    func testClaudeCodeLegacyPluginIDIsOutdatedEvenAboveTheRequiredVersion() {
        // The legacy id means the wrong marketplace, which no version number can
        // fix. Pinned so that bumping `requiredPluginVersion` past 0.1.0 — or
        // anything else that makes the version comparison incidentally true — can
        // never be what this case is relying on.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [Self.claudeRegistryPath: Self.legacyClaudeRegistry(version: "99.0.0")]))
        XCTAssertEqual(probe.status(for: .claudeCode), .outdated(installed: "99.0.0"))
    }

    func testClaudeCodeCurrentPluginIDOutranksALeftoverLegacyRegistration() {
        // A migrated user whose old registration is still on disk is current.
        let registry = """
            {"version": 2,
             "plugins": {
               "\(AgentIntegration.legacyPluginID)": [{"scope": "user", "version": "0.1.0"}],
               "\(AgentIntegration.pluginID)": [{"scope": "user", "version": "\(Self.currentVersion)"}]}}
            """
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(executables: ["claude"], files: [Self.claudeRegistryPath: registry]))
        XCTAssertEqual(probe.status(for: .claudeCode), .installed)
    }

    func testClaudeCodeDisabledUnderTheLegacyIDReportsMissing() {
        // A pre-rename user's enablement key is the legacy id too.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [
                    Self.claudeRegistryPath: Self.legacyClaudeRegistry(version: "0.1.0"),
                    Self.claudeSettingsPath:
                        #"{"enabledPlugins": {"\#(AgentIntegration.legacyPluginID)": false}}"#,
                ]))
        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
    }

    func testClaudeCodeDisabledInSettingsReportsMissing() {
        // Installed but switched off: the plugin is registered and none of its
        // hooks fire, so it reads as absent — the same rule as a disabled Codex.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: fullyInstalledFiles.merging([
                    Self.claudeSettingsPath: #"{"enabledPlugins": {"\#(AgentIntegration.pluginID)": false}}"#
                ]) { _, new in new }))
        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
    }

    func testClaudeCodeEnabledInSettingsStaysInstalled() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: fullyInstalledFiles.merging([
                    Self.claudeSettingsPath: #"{"enabledPlugins": {"\#(AgentIntegration.pluginID)": true}}"#
                ]) { _, new in new }))
        XCTAssertEqual(probe.status(for: .claudeCode), .installed)
    }

    func testClaudeCodeSettingsWithoutAnEntryStaysInstalled() {
        // Enablement can be project-scoped, so an absent global key means enabled.
        // Reading it as disabled would nag every correctly-installed user.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: fullyInstalledFiles.merging([
                    Self.claudeSettingsPath: #"{"enabledPlugins": {"notes@market": false}}"#
                ]) { _, new in new }))
        XCTAssertEqual(probe.status(for: .claudeCode), .installed)
    }

    func testClaudeCodeDisabledOutranksAnOutdatedVersion() {
        // Disabled is reported over outdated: telling the user to update a plugin
        // they switched off would send them to the wrong fix.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: [
                    Self.claudeRegistryPath: Self.claudeRegistry(version: Self.oldVersion),
                    Self.claudeSettingsPath:
                        #"{"enabledPlugins": {"\#(AgentIntegration.pluginID)": false}}"#,
                ]))
        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
    }

    // MARK: - opencode

    func testOpencodeMissingWhenNeitherPluginFileNorConfigEntryExists() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: [Self.opencodeConfigPath: #"{"plugin": ["some-other-plugin"]}"#],
                directories: [Self.opencodePluginPath: ["other.js"]]))
        XCTAssertEqual(probe.status(for: .opencode), .missing)
    }

    func testOpencodeFoundInPluginDirectory() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: ["\(Self.opencodePluginPath)/casper.js": Self.opencodePlugin(version: Self.currentVersion)],
                directories: [Self.opencodePluginPath: ["casper.js"]]))
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    func testOpencodeFoundInPluralPluginsDirectory() {
        // opencode's loader globs `{plugin,plugins}/*.js`; both spellings occur.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: ["\(Self.opencodePluginsPath)/casper.js": Self.opencodePlugin(version: Self.oldVersion)],
                directories: [Self.opencodePluginsPath: ["casper.js"]]))
        XCTAssertEqual(probe.status(for: .opencode), .outdated(installed: Self.oldVersion))
    }

    func testOpencodeFoundInJSONConfigAlone() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: [Self.opencodeConfigPath: Self.opencodeConfig]))
        // A config-only install has no local file to read a version from.
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    func testOpencodeFoundInJSONCConfigAlone() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: [
                    Self.opencodeConfigJSONCPath: """
                        {
                          // installed by the casper-skills installer
                          "$schema": "https://opencode.ai/config.json",
                          "plugin": ["casper-skills@0.2.0"]
                        }
                        """
                ]))
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    func testOpencodeFoundInJSONCConfigPointingAtALocalCheckout() {
        // The install `opencode plugin <spec> -g` performs writes the spec verbatim
        // and copies no file into the plugin directories, so a contributor running
        // from a working copy has nothing on disk but this one config entry.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: [
                    Self.opencodeConfigJSONCPath: #"""
                        {
                          "$schema": "https://opencode.ai/config.json",
                          "plugin": [
                            "/Users/alex/Projects/personal/casper-skills"
                          ]
                        }
                        """#
                ]))
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    func testOpencodeWithUnreadableVersionIsInstalledNotOutdated() {
        // The plugin file is listed but its contents cannot be read, and a plugin
        // whose version is unknown must never produce a nag.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                directories: [Self.opencodePluginPath: ["casper.js"]]))
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    func testOpencodePluginFileWithoutVersionConstantIsInstalled() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["opencode"],
                files: ["\(Self.opencodePluginPath)/casper.js": "export const CasperPlugin = async () => ({})"],
                directories: [Self.opencodePluginPath: ["casper.js"]]))
        XCTAssertEqual(probe.status(for: .opencode), .installed)
    }

    // MARK: - Codex

    func testCodexMissingWhenCacheIsEmpty() {
        let probe = AgentIntegrationProbe(environment: makeEnvironment(executables: ["codex"]))
        XCTAssertEqual(probe.status(for: .codex), .missing)
    }

    func testCodexMissingWhenMarketplaceHoldsOtherPluginsOnly() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                directories: [
                    Self.codexCachePath: ["some-marketplace"],
                    "\(Self.codexCachePath)/some-marketplace": ["other-plugin"],
                ]))
        XCTAssertEqual(probe.status(for: .codex), .missing)
    }

    func testCodexInstalledWhenCurrentAndItsHooksAreTrusted() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: Self.codexConfigHooksTrusted],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installed)
    }

    func testCodexAwaitsHookTrustWithoutAConfig() {
        // Nothing on disk records an approval, so nothing says the hooks run. The
        // install is real; it is simply one `/hooks` visit short of doing anything.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(executables: ["codex"], directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installedAwaitingHookTrust)
    }

    func testCodexTrustsAnUnreadableConfig() {
        // The config is there — `~/.codex` lists it — but its bytes will not come
        // back. That answers neither question it is consulted for, and unknown stays
        // quiet: nagging a user whose hooks are approved, permanently, because one
        // file is unreadable is exactly the false nag this feature refuses to produce.
        var directories = fullyInstalledDirectories
        directories["\(Self.home)/.codex"] = ["config.toml"]
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(executables: ["codex"], directories: directories))
        XCTAssertEqual(probe.status(for: .codex), .installed)
    }

    func testCodexAwaitsHookTrustWhenTheConfigHasNoHooksState() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: #"model = "gpt-5""#],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installedAwaitingHookTrust)
    }

    func testCodexAwaitsHookTrustWhenOnlyOtherHooksAreTrusted() {
        let config = """
            [hooks.state]

            [hooks.state."/stub-home/.codex/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:86cfa1963b6b"

            [hooks.state."notes@some-marketplace:hooks/hooks.json:stop:0:0"]
            trusted_hash = "sha256:11223344556677"
            """
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: config],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installedAwaitingHookTrust)
    }

    func testCodexAwaitsHookTrustWhenItsOnlyTrustedHookIsDisabled() {
        let config = """
            [hooks.state."\(AgentIntegration.pluginID):hooks/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:63ef580c6830"
            enabled = false
            """
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: config],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installedAwaitingHookTrust)
    }

    func testCodexOutdatedCarriesTheHighestCachedVersion() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                directories: [
                    Self.codexCachePath: ["casper"],
                    Self.codexMarketplacePath: ["casper"],
                    Self.codexPluginPath: ["0.0.1", "0.0.2"],
                ]))
        XCTAssertEqual(probe.status(for: .codex), .outdated(installed: "0.0.2"))
    }

    func testCodexTakesTheHighestVersionAcrossMarketplaces() {
        // `contentsOfDirectory` returns marketplaces in no defined order, so
        // stopping at the first one holding the plugin reports an arbitrary
        // install: a user who installed 0.0.1 from one marketplace and the current
        // version from another would be nagged depending on enumeration order.
        for marketplaces in [["alpha", "beta"], ["beta", "alpha"]] {
            let probe = AgentIntegrationProbe(
                environment: makeEnvironment(
                    executables: ["codex"],
                    files: [Self.codexConfigPath: Self.codexConfigHooksTrusted],
                    directories: [
                        Self.codexCachePath: marketplaces,
                        "\(Self.codexCachePath)/alpha": ["casper"],
                        "\(Self.codexCachePath)/alpha/casper": [Self.oldVersion],
                        "\(Self.codexCachePath)/beta": ["casper"],
                        "\(Self.codexCachePath)/beta/casper": [Self.currentVersion],
                    ]))
            XCTAssertEqual(probe.status(for: .codex), .installed, "order=\(marketplaces)")
        }
    }

    func testCodexOutdatedOnlyWhenEveryMarketplaceIsStale() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                directories: [
                    Self.codexCachePath: ["alpha", "beta"],
                    "\(Self.codexCachePath)/alpha": ["casper"],
                    "\(Self.codexCachePath)/alpha/casper": ["0.0.1"],
                    "\(Self.codexCachePath)/beta": ["casper"],
                    "\(Self.codexCachePath)/beta/casper": ["0.0.2"],
                ]))
        XCTAssertEqual(probe.status(for: .codex), .outdated(installed: "0.0.2"))
    }

    func testCodexDisabledInConfigReportsMissing() {
        // An install the user has switched off does nothing, so it reads as absent.
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: Self.codexConfigDisabled],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .missing)
    }

    func testCodexDisabledInConfigOutranksTrustedHooks() {
        // Hooks approved once and the plugin switched off since: the plugin is the
        // problem to report, and it is the one the user has to fix first.
        let config = "\(Self.codexConfigDisabled)\n\n\(Self.codexConfigHooksTrusted)"
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: config],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .missing)
    }

    func testCodexEnabledInConfigStaysInstalled() {
        let enabled = "[plugins.\"\(AgentIntegration.pluginID)\"]\nenabled = true\n"
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["codex"],
                files: [Self.codexConfigPath: "\(enabled)\n\(Self.codexConfigHooksTrusted)"],
                directories: fullyInstalledDirectories))
        XCTAssertEqual(probe.status(for: .codex), .installed)
    }

    // MARK: - Degradation

    func testGarbageEverywhereDegradesToMissing() {
        let garbage = "\u{0}\u{1}not json, not toml, not javascript \u{FFFD}"
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude", "codex", "opencode"],
                files: [
                    Self.claudeRegistryPath: garbage,
                    Self.opencodeConfigPath: garbage,
                    Self.opencodeConfigJSONCPath: garbage,
                    Self.codexConfigPath: garbage,
                ],
                directories: [
                    // Listed but holding nothing Casper recognises.
                    Self.opencodePluginPath: [garbage],
                    Self.codexCachePath: [garbage],
                    "\(Self.codexCachePath)/\(garbage)": [garbage],
                ]))

        XCTAssertEqual(probe.status(for: .claudeCode), .missing)
        XCTAssertEqual(probe.status(for: .opencode), .missing)
        XCTAssertEqual(probe.status(for: .codex), .missing)
    }

    // MARK: - statuses()

    func testStatusesCoversEveryAgent() {
        let probe = AgentIntegrationProbe(
            environment: makeEnvironment(
                executables: ["claude"],
                files: fullyInstalledFiles,
                directories: fullyInstalledDirectories))

        let statuses = probe.statuses()
        XCTAssertEqual(statuses.count, CodingAgent.allCases.count)
        for agent in CodingAgent.allCases {
            XCTAssertNotNil(statuses[agent], "\(agent) is missing from statuses()")
        }
        XCTAssertEqual(statuses[.claudeCode], .installed)
        XCTAssertEqual(statuses[.codex], .notInstalled)
        XCTAssertEqual(statuses[.opencode], .notInstalled)
    }
}
