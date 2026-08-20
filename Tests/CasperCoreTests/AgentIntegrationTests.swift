import Foundation
import XCTest
@testable import CasperCore

final class AgentIntegrationTests: XCTestCase {

    // MARK: - Agent catalogue

    func testEveryAgentHasDistinctIdentity() {
        let names = CodingAgent.allCases.map(\.displayName)
        let executables = CodingAgent.allCases.map(\.executableName)
        XCTAssertEqual(Set(names).count, CodingAgent.allCases.count)
        XCTAssertEqual(Set(executables).count, CodingAgent.allCases.count)
        // opencode styles its own name lowercase; that is not a typo to fix.
        XCTAssertEqual(CodingAgent.opencode.displayName, "opencode")
    }

    func testReminderIDsAreStableAndDistinct() {
        // These ids live in the user's `session.json`, so they are pinned here
        // rather than derived: changing one silently discards every dismissal a
        // user has already made. They are deliberately not `rawValue`.
        XCTAssertEqual(CodingAgent.claudeCode.reminderID, "claude-code")
        XCTAssertEqual(CodingAgent.codex.reminderID, "codex")
        XCTAssertEqual(CodingAgent.opencode.reminderID, "opencode")

        let ids = CodingAgent.allCases.map(\.reminderID)
        XCTAssertEqual(Set(ids).count, CodingAgent.allCases.count)
    }

    func testOnlyCodexRequiresHookTrust() {
        XCTAssertTrue(CodingAgent.codex.requiresHookTrust)
        XCTAssertFalse(CodingAgent.claudeCode.requiresHookTrust)
        XCTAssertFalse(CodingAgent.opencode.requiresHookTrust)
    }

    func testDocumentationURLCarriesPerAgentFragment() {
        XCTAssertEqual(
            CodingAgent.claudeCode.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-agents#claude-code")
        XCTAssertEqual(
            CodingAgent.codex.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-agents#codex")
        XCTAssertEqual(
            CodingAgent.opencode.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-agents#opencode")
    }

    func testRequiredPluginVersionIsParseable() {
        // The constant feeds every comparison; an unparseable value would silently
        // disable outdated-detection everywhere.
        XCTAssertTrue(AgentIntegration.isOutdated(installed: "0.0.1", required: AgentIntegration.requiredPluginVersion))
    }

    // MARK: - Version comparison

    func testIsOutdatedComparesNumerically() {
        // (installed, required, expected)
        let cases: [(String, String, Bool)] = [
            ("0.2.0", "0.2.0", false),  // equal
            ("0.1.0", "0.2.0", true),  // older
            ("0.3.0", "0.2.0", false),  // newer than this Casper build
            ("0.2", "0.2.0", false),  // missing components are zero
            ("0.2.0", "0.2", false),
            ("0.1", "0.2.0", true),
            ("1", "0.9.9", false),
            ("0.9.0", "0.10.0", true),  // a string compare gets this backwards
            ("0.10.0", "0.9.0", false),
            ("0.2.0.0", "0.2.0", false),
            ("0.2.0.1", "0.2.0", false),
        ]
        for (installed, required, expected) in cases {
            XCTAssertEqual(
                AgentIntegration.isOutdated(installed: installed, required: required),
                expected,
                "installed=\(installed) required=\(required)")
        }
    }

    func testIsOutdatedIgnoresSurroundingWhitespace() {
        XCTAssertTrue(AgentIntegration.isOutdated(installed: " 0.1.0\n", required: "0.2.0"))
        XCTAssertFalse(AgentIntegration.isOutdated(installed: " 0.2.0\n", required: "0.2.0"))
    }

    func testIsOutdatedNeverNagsOnAnUnparseableVersion() {
        // "unknown" is what Claude Code records for a plugin manifest without a
        // `version`, and it really does occur in registry files.
        for installed in ["unknown", "", "   ", "abc", "1.2.x", "1.2.3-beta", "v0.1.0", "0..1", "-1"] {
            XCTAssertFalse(
                AgentIntegration.isOutdated(installed: installed, required: "0.2.0"),
                "installed=\(installed)")
        }
    }

    func testIsOutdatedNeverNagsWhenTheRequiredVersionIsUnparseable() {
        XCTAssertFalse(AgentIntegration.isOutdated(installed: "0.1.0", required: "unknown"))
        XCTAssertFalse(AgentIntegration.isOutdated(installed: "0.1.0", required: ""))
    }

    // MARK: - Claude Code registry

    /// The verified real shape, including a sibling plugin whose manifest omits a
    /// version (Claude Code writes the literal "unknown" for those).
    private let claudeRegistry = #"""
        {
          "version": 2,
          "plugins": {
            "casper@casper-agents": [
              {
                "scope": "user",
                "installPath": "/Users/alex/.claude/plugins/cache/casper-agents/casper",
                "version": "0.2.0",
                "installedAt": "2026-08-19T09:12:00Z",
                "lastUpdated": "2026-08-19T09:12:00Z"
              }
            ],
            "notes@some-marketplace": [
              {
                "scope": "user",
                "installPath": "/Users/alex/.claude/plugins/cache/some-marketplace/notes",
                "version": "unknown",
                "installedAt": "2026-07-01T10:00:00Z",
                "lastUpdated": "2026-07-01T10:00:00Z"
              }
            ]
          }
        }
        """#

    func testParseClaudeRegistryReadsTheInstalledVersion() {
        let version = AgentIntegration.parseClaudeRegistry(Data(claudeRegistry.utf8))
        XCTAssertEqual(version, "0.2.0")
    }

    func testParseClaudeRegistryIgnoresOtherPlugins() {
        let version = AgentIntegration.parseClaudeRegistry(
            Data(claudeRegistry.utf8), pluginID: "notes@some-marketplace")
        // Returned verbatim: `isOutdated` is the single place that judges it.
        XCTAssertEqual(version, "unknown")
    }

    func testParseClaudeRegistryReturnsNilForAnUnregisteredPlugin() {
        let version = AgentIntegration.parseClaudeRegistry(Data(claudeRegistry.utf8), pluginID: "nope@nowhere")
        XCTAssertNil(version)
    }

    func testParseClaudeRegistryTakesTheHighestRecordedVersion() {
        // One array entry per scope, in no meaningful order: a stale project-scope
        // record ahead of a current user-scope one must not produce a false
        // "outdated". Same policy as the Codex cache.
        let json = #"""
            {"plugins": {"casper@casper-agents": [
              {"scope": "project"},
              {"scope": "user", "version": "0.1.0"},
              {"scope": "local", "version": "0.9.0"}
            ]}}
            """#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(json.utf8)), "0.9.0")

        // Numerically, not lexicographically.
        let doubleDigit = #"""
            {"plugins": {"casper@casper-agents": [
              {"version": "0.10.0"}, {"version": "0.9.0"}
            ]}}
            """#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(doubleDigit.utf8)), "0.10.0")
    }

    func testParseClaudeRegistrySurvivesEveryMalformedShape() {
        let malformed: [String] = [
            "",  // empty file
            "not json at all",
            "[]",  // top level is not an object
            #"{"version": 2}"#,  // no `plugins` key
            #"{"plugins": []}"#,  // `plugins` is not an object
            #"{"plugins": {"casper@casper-agents": {"version": "0.2.0"}}}"#,  // record is not an array
            #"{"plugins": {"casper@casper-agents": []}}"#,  // empty array
            #"{"plugins": {"casper@casper-agents": [{}]}}"#,  // record without a version
            #"{"plugins": {"casper@casper-agents": [{"version": 2}]}}"#,  // version is not a string
            #"{"plugins": {"casper@casper-agents": ["oops"]}}"#,  // record is not an object
        ]
        for json in malformed {
            XCTAssertNil(AgentIntegration.parseClaudeRegistry(Data(json.utf8)), "json=\(json)")
        }
    }

    func testParseClaudeRegistrySkipsNonObjectRecords() {
        let json = #"{"plugins": {"casper@casper-agents": ["oops", {"version": "0.2.0"}]}}"#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(json.utf8)), "0.2.0")
    }

    // MARK: - Claude Code enablement

    func testParseClaudeEnabledReadsAnExplicitFalse() {
        let settings = #"{"enabledPlugins": {"casper@casper-agents": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)))
    }

    func testParseClaudeEnabledReadsAnExplicitTrue() {
        let settings = #"{"enabledPlugins": {"casper@casper-agents": true}}"#
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)))
    }

    func testParseClaudeEnabledTreatsAnAbsentKeyAsEnabled() {
        // The map holds only plugins whose global state the user has touched, and
        // enablement can also be project-scoped, so an absent key is evidence of
        // nothing — never of a disabled plugin.
        let cases = [
            #"{"enabledPlugins": {"notes@some-marketplace": false}}"#,
            #"{"enabledPlugins": {}}"#,
            #"{"model": "opus"}"#,
        ]
        for settings in cases {
            XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)), "settings=\(settings)")
        }
    }

    func testParseClaudeEnabledIsScopedToTheGivenPlugin() {
        let settings = #"{"enabledPlugins": {"casper@casper-agents": true, "notes@market": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(settings.utf8), pluginID: "notes@market"))
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8), pluginID: "casper@casper-agents"))
    }

    func testParseClaudeEnabledNeverDisablesOnAMalformedFile() {
        // A settings file Casper cannot read is no reason to claim the integration
        // is missing.
        let malformed = [
            "",
            "not json at all",
            "[]",
            #"{"enabledPlugins": []}"#,
            #"{"enabledPlugins": {"casper@casper-agents": "false"}}"#,  // string, not bool
        ]
        for settings in malformed {
            XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)), "settings=\(settings)")
        }
    }

    func testParseClaudeEnabledReadsANumericFlagThroughNSNumberBridging() {
        // `JSONSerialization` hands a JSON number back as `NSNumber`, which casts to
        // `Bool`. Pinned rather than worked around: someone who writes `0` there
        // means false.
        let disabled = #"{"enabledPlugins": {"casper@casper-agents": 0}}"#
        let enabled = #"{"enabledPlugins": {"casper@casper-agents": 1}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(disabled.utf8)))
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(enabled.utf8)))
    }

    // MARK: - opencode config

    func testParseOpencodeConfigWithCommentsAndSchemaURL() {
        // The `//` inside the schema URL must survive comment stripping — this exact
        // line ships in opencode's default config.
        let config = #"""
            {
              // Casper integration, installed by the casper-agents installer.
              "$schema": "https://opencode.ai/config.json",
              /* the plugin list is a plain array of npm package names */
              "plugin": ["casper-agents@0.2.0"]
            }
            """#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigWithoutCasperEntry() {
        let config = #"""
            {
              "$schema": "https://opencode.ai/config.json",
              "plugin": ["some-other-plugin"]
            }
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigDoesNotMatchAnUnrelatedPluginNamedCasper() {
        // The entry must be the package name exactly (optionally `@version`) or a
        // path whose last component is the plugin file. A substring or a suffix is
        // not enough: `@evil/casper-agents-fork` contains the package name and
        // `./plugin/notcasper.js` ends with the file name, and neither is Casper's.
        let config = #"""
            {"plugin": ["casper-notes", "opencode-casper-theme", "casperjs",
                        "@evil/casper-agents-fork", "./plugin/notcasper.js",
                        "casper-agents-fork", "my-casper-agents"]}
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigMatchesTheExactPackageNameWithOrWithoutAVersion() {
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["casper-agents"]}"#))
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["casper-agents@0.2.0"]}"#))
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["  casper-agents  "]}"#))
    }

    func testParseOpencodeConfigMatchesALocalPluginPath() {
        let config = #"{"plugin": ["./plugin/casper.js"]}"#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigWithoutAPluginArray() {
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"$schema": "https://opencode.ai/config.json"}"#))
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"plugin": "casper-agents"}"#))
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"plugin": [42]}"#))
    }

    func testParseOpencodeConfigCommentStrippingKeepsEscapedQuotes() {
        let config = #"""
            {
              "note": "a \" quote and a // slash",
              "plugin": ["casper-agents"]
            }
            """#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigCommentedOutEntryIsNotAMatch() {
        let config = #"""
            {
              // "plugin": ["casper-agents"]
              "plugin": []
            }
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigFallsBackWhenUnparseable() {
        // Truncated mid-write: not JSON even after stripping, but the entry is
        // plainly there, so claiming "missing" would be wrong.
        let truncated = #"""
            {
              "$schema": "https://opencode.ai/config.json",
              "plugin": ["casper-agents@0.2.0"
            """#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(truncated))
    }

    func testParseOpencodeConfigFallbackIgnoresACommentedOutEntry() {
        // Unparseable *and* commented out: the fallback scans the comment-stripped
        // text, so the commented entry is not evidence of an install.
        let truncated = #"""
            {
              // "plugin": ["casper-agents"]
              "plugin": [
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(truncated))
    }

    func testParseOpencodeConfigFallbackStillRejectsAnAbsentEntry() {
        let truncated = #"""
            {
              "$schema": "https://opencode.ai/config.json",
              "plugin": ["some-other-plugin"
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(truncated))
    }

    // MARK: - opencode plugin version

    func testParseOpencodeVersionReadsTheCommittedForm() {
        let source = """
            import { casper } from "./casper-agents"

            export const CASPER_PLUGIN_VERSION = "0.2.0"

            export const Casper = async ({ client }) => ({})
            """
        XCTAssertEqual(AgentIntegration.parseOpencodeVersion(source), "0.2.0")
    }

    func testParseOpencodeVersionToleratesSemicolonAndSpacing() {
        XCTAssertEqual(
            AgentIntegration.parseOpencodeVersion(#"export const CASPER_PLUGIN_VERSION = "0.2.0";"#), "0.2.0")
        XCTAssertEqual(
            AgentIntegration.parseOpencodeVersion(#"export const CASPER_PLUGIN_VERSION="0.3.1""#), "0.3.1")
        XCTAssertEqual(
            AgentIntegration.parseOpencodeVersion(#"  export const CASPER_PLUGIN_VERSION   =   "1.0.0"  "#), "1.0.0")
    }

    func testParseOpencodeVersionMissesASingleQuotedDeclaration() {
        // Deliberate: the shipped plugin uses double quotes, and a miss degrades to
        // "installed, version unreadable" — never to a nag.
        XCTAssertNil(AgentIntegration.parseOpencodeVersion("export const CASPER_PLUGIN_VERSION = '0.2.0'"))
    }

    func testParseOpencodeVersionReturnsNilWhenAbsent() {
        XCTAssertNil(AgentIntegration.parseOpencodeVersion("export const Casper = async () => ({})"))
        XCTAssertNil(AgentIntegration.parseOpencodeVersion(""))
    }

    func testParseOpencodeVersionIgnoresCommentsAndLongerIdentifiers() {
        // Both edges of the identifier are anchored: a namesake that merely ends
        // with it (`PREV_CASPER_PLUGIN_VERSION`) is as wrong an answer as one that
        // starts with it (`CASPER_PLUGIN_VERSION_LEGACY`).
        let source = #"""
            // export const CASPER_PLUGIN_VERSION = "9.9.9"
            /* export const CASPER_PLUGIN_VERSION = "8.8.8" */
            const CASPER_PLUGIN_VERSION_LEGACY = "0.0.1"
            const PREV_CASPER_PLUGIN_VERSION = "0.0.2"
            """#
        XCTAssertNil(AgentIntegration.parseOpencodeVersion(source))
    }

    func testParseOpencodeVersionPrefersTheRealDeclarationOverANamesake() {
        let suffixed = #"""
            const CASPER_PLUGIN_VERSION_LEGACY = "0.0.1"
            export const CASPER_PLUGIN_VERSION = "0.2.0"
            """#
        XCTAssertEqual(AgentIntegration.parseOpencodeVersion(suffixed), "0.2.0")

        let prefixed = #"""
            const PREV_CASPER_PLUGIN_VERSION = "0.0.1"
            export const CASPER_PLUGIN_VERSION = "0.2.0"
            """#
        XCTAssertEqual(AgentIntegration.parseOpencodeVersion(prefixed), "0.2.0")
    }

    // MARK: - Codex cache

    func testParseCodexCacheEntriesPicksTheHighestVersion() {
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries(["0.1.0", "0.10.0", "0.9.0"]), "0.10.0")
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries(["0.2.0"]), "0.2.0")
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries(["1.0", "0.9.9"]), "1.0")
    }

    func testParseCodexCacheEntriesIgnoresNonVersionDirectories() {
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries([".DS_Store", "tmp", "0.2.0"]), "0.2.0")
    }

    func testParseCodexCacheEntriesReturnsNilWhenEmpty() {
        XCTAssertNil(AgentIntegration.parseCodexCacheEntries([]))
    }

    func testParseCodexCacheEntriesIgnoresDotFiles() {
        // An uninstall that leaves the directory behind with a Finder artefact in
        // it must read as absent, not as a plugin whose version is ".DS_Store".
        XCTAssertNil(AgentIntegration.parseCodexCacheEntries([".DS_Store"]))
        XCTAssertNil(AgentIntegration.parseCodexCacheEntries([".DS_Store", ".localized"]))
        // A *visible* unparseable name still counts as installed: Claude Code's
        // registry records real install paths ending in `/unknown`.
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries([".DS_Store", "unknown"]), "unknown")
    }

    func testParseCodexCacheEntriesReportsAnUnrecognisedLayoutAsInstalled() {
        // Something is installed, just not in a shape Casper understands. Reporting a
        // name keeps the status at "installed" instead of a false "missing".
        XCTAssertEqual(AgentIntegration.parseCodexCacheEntries(["main", "head"]), "main")
    }

    // MARK: - Codex disabled flag

    func testParseCodexDisabledReadsTheDisabledSection() {
        let toml = #"""
            model = "gpt-5"

            [plugins."casper@casper-agents"]
            enabled = false
            """#
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(toml))
    }

    func testParseCodexDisabledAcceptsSpacingCommentsAndAnUnquotedHeader() {
        let spaced = #"""
            [plugins."casper@casper-agents"]
              enabled   =   false   # turned off while debugging
            """#
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(spaced))

        let unquoted = """
            [plugins.casper@casper-agents]
            enabled = false
            """
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(unquoted))
    }

    func testParseCodexEnabledSectionIsNotDisabled() {
        let toml = #"""
            [plugins."casper@casper-agents"]
            enabled = true
            """#
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(toml))
    }

    func testParseCodexAbsentSectionMeansEnabled() {
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(""))
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(#"model = "gpt-5""#))
    }

    func testParseCodexDisabledReadsACRLFConfig() {
        // `.whitespaces` excludes `\r`, so a CRLF config used to leave the header
        // and the value each carrying a trailing carriage return and match nothing.
        let toml = "[plugins.\"\(AgentIntegration.pluginID)\"]\r\nenabled = false\r\n"
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(toml))

        let enabled = "[plugins.\"\(AgentIntegration.pluginID)\"]\r\nenabled = true\r\n"
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(enabled))
    }

    func testParseCodexDisabledIgnoresAnotherPluginsSection() {
        let toml = #"""
            [plugins."notes@some-marketplace"]
            enabled = false

            [plugins."casper@casper-agents"]
            enabled = true
            """#
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(toml))
    }

    func testParseCodexDisabledStopsAtTheNextSectionHeader() {
        // The `enabled = false` belongs to the section that follows, not to Casper's.
        let toml = #"""
            [plugins."casper@casper-agents"]

            [plugins."notes@some-marketplace"]
            enabled = false
            """#
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(toml))
    }
}
