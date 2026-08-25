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

    func testLegacyPluginIDIsPinnedAndDistinct() {
        // Deterministic, not per-user: a Claude Code plugin id is
        // `<plugin>@<marketplace>`, and the pre-rename marketplace declared
        // `"name": "Casper"`, so every pre-rename install carries this exact key.
        // Changing it turns all of those users back into a false `.missing`.
        XCTAssertEqual(AgentIntegration.legacyPluginID, "casper@Casper")
        XCTAssertNotEqual(AgentIntegration.legacyPluginID, AgentIntegration.pluginID)
    }

    func testPluginIDAndLegacyPluginIDDifferByCaseAlone() {
        XCTAssertEqual(AgentIntegration.pluginID, "casper@casper")

        // The two ids are one capital letter apart, which is exactly what makes them
        // fragile: they must stay *different strings* (or a pre-rename install stops
        // being recognised as legacy), yet they are *equal once folded* — so any move
        // to case-insensitive matching would conflate them instead of telling them
        // apart. Both halves are asserted so a future edit breaking either one fails
        // here rather than in a user's registry.
        XCTAssertNotEqual(AgentIntegration.pluginID, AgentIntegration.legacyPluginID)
        XCTAssertEqual(AgentIntegration.pluginID.lowercased(), AgentIntegration.legacyPluginID.lowercased())
    }

    func testDocumentationURLCarriesPerAgentFragment() {
        XCTAssertEqual(
            CodingAgent.claudeCode.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-skills#claude-code")
        XCTAssertEqual(
            CodingAgent.codex.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-skills#codex")
        XCTAssertEqual(
            CodingAgent.opencode.documentationURL.absoluteString,
            "https://github.com/alexandreroman/casper-skills#opencode")
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
            "casper@casper": [
              {
                "scope": "user",
                "installPath": "/Users/alex/.claude/plugins/cache/casper/casper",
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
        let registration = AgentIntegration.parseClaudeRegistry(Data(claudeRegistry.utf8))
        XCTAssertEqual(registration, .init(version: "0.2.0", usesLegacyPluginID: false))
    }

    func testParseClaudeRegistryIgnoresOtherPlugins() {
        let registration = AgentIntegration.parseClaudeRegistry(
            Data(claudeRegistry.utf8), pluginID: "notes@some-marketplace")
        // Returned verbatim: `isOutdated` is the single place that judges it.
        XCTAssertEqual(registration?.version, "unknown")
    }

    func testParseClaudeRegistryReturnsNilForAnUnregisteredPlugin() {
        let registration = AgentIntegration.parseClaudeRegistry(Data(claudeRegistry.utf8), pluginID: "nope@nowhere")
        XCTAssertNil(registration)
    }

    func testParseClaudeRegistryTakesTheHighestRecordedVersion() {
        // One array entry per scope, in no meaningful order: a stale project-scope
        // record ahead of a current user-scope one must not produce a false
        // "outdated". Same policy as the Codex cache.
        let json = #"""
            {"plugins": {"casper@casper": [
              {"scope": "project"},
              {"scope": "user", "version": "0.1.0"},
              {"scope": "local", "version": "0.9.0"}
            ]}}
            """#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(json.utf8))?.version, "0.9.0")

        // Numerically, not lexicographically.
        let doubleDigit = #"""
            {"plugins": {"casper@casper": [
              {"version": "0.10.0"}, {"version": "0.9.0"}
            ]}}
            """#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(doubleDigit.utf8))?.version, "0.10.0")
    }

    func testParseClaudeRegistrySurvivesEveryMalformedShape() {
        let malformed: [String] = [
            "",  // empty file
            "not json at all",
            "[]",  // top level is not an object
            #"{"version": 2}"#,  // no `plugins` key
            #"{"plugins": []}"#,  // `plugins` is not an object
            #"{"plugins": {"casper@casper": {"version": "0.2.0"}}}"#,  // record is not an array
            #"{"plugins": {"casper@casper": []}}"#,  // empty array
            #"{"plugins": {"casper@casper": [{}]}}"#,  // record without a version
            #"{"plugins": {"casper@casper": [{"version": 2}]}}"#,  // version is not a string
            #"{"plugins": {"casper@casper": ["oops"]}}"#,  // record is not an object
        ]
        for json in malformed {
            XCTAssertNil(AgentIntegration.parseClaudeRegistry(Data(json.utf8)), "json=\(json)")
        }
    }

    func testParseClaudeRegistrySkipsNonObjectRecords() {
        let json = #"{"plugins": {"casper@casper": ["oops", {"version": "0.2.0"}]}}"#
        XCTAssertEqual(AgentIntegration.parseClaudeRegistry(Data(json.utf8))?.version, "0.2.0")
    }

    /// A genuine pre-rename registry entry, copied verbatim off a real machine —
    /// `installPath` and `gitCommitSha` included — so the legacy path is proved
    /// against the shape Claude Code actually writes, not a tidied-up stand-in.
    private let legacyClaudeRegistry = #"""
        {
          "version": 2,
          "plugins": {
            "casper@Casper": [
              {
                "scope": "user",
                "installPath": "/Users/alex/.claude/plugins/cache/Casper/casper/0.1.0",
                "version": "0.1.0",
                "installedAt": "2026-07-07T13:04:49.792Z",
                "lastUpdated": "2026-07-07T13:04:49.792Z",
                "gitCommitSha": "17fd..."
              }
            ]
          }
        }
        """#

    func testParseClaudeRegistryMatchesTheLegacyPluginID() {
        let registration = AgentIntegration.parseClaudeRegistry(Data(legacyClaudeRegistry.utf8))
        XCTAssertEqual(registration, .init(version: "0.1.0", usesLegacyPluginID: true))
    }

    func testParseClaudeRegistryFlagsTheLegacyPluginIDWhateverTheVersion() {
        // The flag reports the *id* that matched, never the version, so a legacy
        // install numbered above `requiredPluginVersion` is still flagged. That is
        // what keeps a future version bump from quietly losing these users.
        let json = #"""
            {"plugins": {"casper@Casper": [{"scope": "user", "version": "99.0.0"}]}}
            """#
        XCTAssertEqual(
            AgentIntegration.parseClaudeRegistry(Data(json.utf8)),
            .init(version: "99.0.0", usesLegacyPluginID: true))
    }

    func testParseClaudeRegistryPrefersTheCurrentPluginIDOverTheLegacyOne() {
        // A user who migrated but left the old registration behind is current. The
        // legacy record here holds the *higher* version on purpose: the choice is
        // made on the id, not by comparing versions across the two.
        let json = #"""
            {"plugins": {
              "casper@Casper": [{"scope": "user", "version": "99.0.0"}],
              "casper@casper": [{"scope": "user", "version": "0.2.0"}]
            }}
            """#
        XCTAssertEqual(
            AgentIntegration.parseClaudeRegistry(Data(json.utf8)),
            .init(version: "0.2.0", usesLegacyPluginID: false))
    }

    func testParseClaudeRegistryReturnsNilWhenNeitherIDIsRegistered() {
        let json = #"{"version": 2, "plugins": {"notes@some-marketplace": [{"version": "1.0.0"}]}}"#
        XCTAssertNil(AgentIntegration.parseClaudeRegistry(Data(json.utf8)))
    }

    // MARK: - Claude Code enablement

    func testParseClaudeEnabledReadsAnExplicitFalse() {
        let settings = #"{"enabledPlugins": {"casper@casper": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)))
    }

    func testParseClaudeEnabledReadsAnExplicitTrue() {
        let settings = #"{"enabledPlugins": {"casper@casper": true}}"#
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)))
    }

    func testParseClaudeEnabledReadsAnExplicitFalseUnderEitherID() {
        // A pre-rename user's key here is the legacy id, so reading only the current
        // one would report an integration they switched off as live.
        let legacyOnly = #"{"enabledPlugins": {"casper@Casper": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(legacyOnly.utf8)))

        // Either key alone is enough to disable, so a leftover legacy `false` counts
        // even beside a current `true`: an explicit `false` on this plugin is the
        // user's own statement about the Casper integration, whichever id carries it.
        let both = #"{"enabledPlugins": {"casper@casper": true, "casper@Casper": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(both.utf8)))
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
        let settings = #"{"enabledPlugins": {"casper@casper": true, "notes@market": false}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(settings.utf8), pluginID: "notes@market"))
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8), pluginID: "casper@casper"))
    }

    func testParseClaudeEnabledNeverDisablesOnAMalformedFile() {
        // A settings file Casper cannot read is no reason to claim the integration
        // is missing.
        let malformed = [
            "",
            "not json at all",
            "[]",
            #"{"enabledPlugins": []}"#,
            #"{"enabledPlugins": {"casper@casper": "false"}}"#,  // string, not bool
        ]
        for settings in malformed {
            XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(settings.utf8)), "settings=\(settings)")
        }
    }

    func testParseClaudeEnabledReadsANumericFlagThroughNSNumberBridging() {
        // `JSONSerialization` hands a JSON number back as `NSNumber`, which casts to
        // `Bool`. Pinned rather than worked around: someone who writes `0` there
        // means false.
        let disabled = #"{"enabledPlugins": {"casper@casper": 0}}"#
        let enabled = #"{"enabledPlugins": {"casper@casper": 1}}"#
        XCTAssertFalse(AgentIntegration.parseClaudeEnabled(Data(disabled.utf8)))
        XCTAssertTrue(AgentIntegration.parseClaudeEnabled(Data(enabled.utf8)))
    }

    // MARK: - opencode config

    func testParseOpencodeConfigWithCommentsAndSchemaURL() {
        // The `//` inside the schema URL must survive comment stripping — this exact
        // line ships in opencode's default config.
        let config = #"""
            {
              // Casper integration, installed by the casper-skills installer.
              "$schema": "https://opencode.ai/config.json",
              /* the plugin list is a plain array of plugin specs */
              "plugin": ["casper-skills@0.2.0"]
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
        // not enough: `@evil/casper-skills-fork` contains the package name and
        // `./plugin/notcasper.js` ends with the file name, and neither is Casper's.
        let config = #"""
            {"plugin": ["casper-notes", "opencode-casper-theme", "casperjs",
                        "@evil/casper-skills-fork", "./plugin/notcasper.js",
                        "casper-skills-fork", "my-casper-skills"]}
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigMatchesTheExactPackageNameWithOrWithoutAVersion() {
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["casper-skills"]}"#))
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["casper-skills@0.2.0"]}"#))
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["  casper-skills  "]}"#))
    }

    func testParseOpencodeConfigMatchesALocalPluginPath() {
        let config = #"{"plugin": ["./plugin/casper.js"]}"#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigMatchesEveryDocumentedGitSpec() {
        // `opencode plugin <spec> -g` writes the spec verbatim, and the plugin's
        // README documents the GitHub shorthand plus "any Git spec" alongside it.
        // Each form ends in the repository name, which is what the matcher reads.
        for entry in [
            "github:alexandreroman/casper-skills",
            "github:alexandreroman/casper-skills#main",
            "git+https://github.com/alexandreroman/casper-skills.git",
            "git+ssh://git@github.com/alexandreroman/casper-skills.git",
            "git@github.com:alexandreroman/casper-skills.git",
            "file:///Users/alex/Projects/personal/casper-skills",
        ] {
            XCTAssertTrue(
                AgentIntegration.parseOpencodeConfig(#"{"plugin": ["\#(entry)"]}"#),
                "expected \(entry) to read as installed")
        }
    }

    func testParseOpencodeConfigMatchesALocalCheckoutDirectory() {
        // Pointing the config at a working copy is how a contributor runs the plugin,
        // and the trailing slash is a spelling a shell's tab completion produces.
        for entry in [
            "/Users/alex/Projects/personal/casper-skills",
            "/Users/alex/Projects/personal/casper-skills/",
            "~/src/casper-skills",
        ] {
            XCTAssertTrue(
                AgentIntegration.parseOpencodeConfig(#"{"plugin": ["\#(entry)"]}"#),
                "expected \(entry) to read as installed")
        }
    }

    func testParseOpencodeConfigMatchesAForkOfThePluginRepository() {
        // Deliberate: the matcher reads the repository name, so a fork counts as
        // installed. A fork carries the integration, and a false "install the plugin"
        // nag costs more trust than a missed one.
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(#"{"plugin": ["github:someone/casper-skills"]}"#))
    }

    func testParseOpencodeConfigDoesNotMatchAGitSpecForAnotherRepository() {
        let config = #"""
            {"plugin": ["github:evil/casper-skills-fork",
                        "git+https://github.com/evil/not-casper-skills.git"]}
            """#
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigWithoutAPluginArray() {
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"$schema": "https://opencode.ai/config.json"}"#))
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"plugin": "casper-skills"}"#))
        XCTAssertFalse(AgentIntegration.parseOpencodeConfig(#"{"plugin": [42]}"#))
    }

    func testParseOpencodeConfigCommentStrippingKeepsEscapedQuotes() {
        let config = #"""
            {
              "note": "a \" quote and a // slash",
              "plugin": ["casper-skills"]
            }
            """#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(config))
    }

    func testParseOpencodeConfigCommentedOutEntryIsNotAMatch() {
        let config = #"""
            {
              // "plugin": ["casper-skills"]
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
              "plugin": ["casper-skills@0.2.0"
            """#
        XCTAssertTrue(AgentIntegration.parseOpencodeConfig(truncated))
    }

    func testParseOpencodeConfigFallbackIgnoresACommentedOutEntry() {
        // Unparseable *and* commented out: the fallback scans the comment-stripped
        // text, so the commented entry is not evidence of an install.
        let truncated = #"""
            {
              // "plugin": ["casper-skills"]
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
            import { casper } from "./casper-skills"

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

            [plugins."casper@casper"]
            enabled = false
            """#
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(toml))
    }

    func testParseCodexDisabledAcceptsSpacingCommentsAndAnUnquotedHeader() {
        let spaced = #"""
            [plugins."casper@casper"]
              enabled   =   false   # turned off while debugging
            """#
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(spaced))

        let unquoted = """
            [plugins.casper@casper]
            enabled = false
            """
        XCTAssertTrue(AgentIntegration.parseCodexDisabled(unquoted))
    }

    func testParseCodexEnabledSectionIsNotDisabled() {
        let toml = #"""
            [plugins."casper@casper"]
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

            [plugins."casper@casper"]
            enabled = true
            """#
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(toml))
    }

    func testParseCodexDisabledStopsAtTheNextSectionHeader() {
        // The `enabled = false` belongs to the section that follows, not to Casper's.
        let toml = #"""
            [plugins."casper@casper"]

            [plugins."notes@some-marketplace"]
            enabled = false
            """#
        XCTAssertFalse(AgentIntegration.parseCodexDisabled(toml))
    }

    // MARK: - Codex hook trust

    /// `[hooks.state]` as Codex 0.149.0 actually writes it: one table per hook, keyed
    /// `"<pluginId>:<hooks file>:<event>:<index>:<index>"`, `enabled` present on only
    /// some entries, and a non-plugin hook whose key is an absolute path instead of a
    /// plugin id.
    private static let codexConfigWithTrustedHooks = #"""
        model = "gpt-5"

        [hooks.state]

        [hooks.state."casper@casper:hooks/hooks.json:pre_tool_use:0:0"]
        trusted_hash = "sha256:cf20c90350d8ff844abbefae4ce2b3c6b78228ff31684cf98e0e97"

        [hooks.state."casper@casper:hooks/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:63ef580c6830c4c80d21164707f0c0afe2daf03eeb2238cb3ee154"
        enabled = true

        [hooks.state."/Users/alex/.codex/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:86cfa1963b6b0f3d2a1c8e4d5b6a7f8091a2b3c4d5e6f708192a3b"
        """#

    func testParseCodexHooksTrustedReadsARealHooksStateTable() {
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(Self.codexConfigWithTrustedHooks))
    }

    func testParseCodexHooksTrustedIgnoresHooksThatAreNotThePlugins() {
        // An absolute-path key is a hook belonging to no plugin, and another plugin's
        // approval says nothing about Casper's. Neither counts.
        let toml = #"""
            [hooks.state]

            [hooks.state."/Users/alex/.codex/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:86cfa1963b6b"

            [hooks.state."notes@some-marketplace:hooks/hooks.json:stop:0:0"]
            trusted_hash = "sha256:11223344556677"
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(toml))
    }

    func testParseCodexHooksTrustedTreatsAnAbsentTableAsUntrusted() {
        // A config with no `[hooks.state]` at all, and no config at all, are the same
        // answer: the user has never been through `/hooks`.
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(""))
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(#"model = "gpt-5""#))
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted("[hooks.state]\n"))
    }

    func testParseCodexHooksTrustedIgnoresAnEntryWithoutAHash() {
        let toml = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"]
            enabled = true
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(toml))

        let empty = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"]
            trusted_hash = ""
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(empty))
    }

    func testParseCodexHooksTrustedIgnoresADisabledEntry() {
        let toml = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"]
            trusted_hash = "sha256:20cbfea5ef2e"
            enabled = false
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(toml))

        // One switched-off hook does not hide the approval recorded for another.
        let alsoTrusted = toml + #"""

            [hooks.state."casper@casper:hooks/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:63ef580c6830"
            """#
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(alsoTrusted))
    }

    func testParseCodexHooksTrustedStopsAtTheNextTableHeader() {
        // The hash belongs to the table that follows, not to Casper's.
        let toml = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"]

            [hooks.state."/Users/alex/.codex/hooks.json:stop:0:0"]
            trusted_hash = "sha256:86cfa1963b6b"
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(toml))
    }

    func testParseCodexHooksTrustedIgnoresAMultiLineArrayInsideTheTable() {
        // The continuation lines of a multi-line array start with `[` and end with a
        // comma or nothing. Taking either for a table header would bank this table's
        // verdict before its `enabled = false` is read — the one direction this parser
        // must never fail in, since it silently suppresses the notice.
        let toml = #"""
            [hooks.state."casper@casper:hooks/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:abc"
            matchers = [
              ["Bash"],
            ]
            enabled = false
            """#
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted(toml))
    }

    func testParseCodexHooksTrustedAcceptsSpacingCommentsAndAnUnquotedHeader() {
        let spaced = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"]
              trusted_hash   =   "sha256:20cbfea5ef2e"   # approved on 2026-08-01
            """#
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(spaced))

        // Spaces inside the brackets are legal TOML, and a header may carry a trailing
        // comment of its own.
        let spacedHeader = #"""
            [ hooks.state."casper@casper:hooks/hooks.json:stop:0:0" ]
            trusted_hash = "sha256:20cbfea5ef2e"
            """#
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(spacedHeader))

        let commentedHeader = #"""
            [hooks.state."casper@casper:hooks/hooks.json:stop:0:0"] # approved
            trusted_hash = "sha256:20cbfea5ef2e"
            """#
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(commentedHeader))

        let unquoted = """
            [hooks.state.casper@casper:hooks/hooks.json:stop:0:0]
            trusted_hash = "sha256:20cbfea5ef2e"
            """
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted(unquoted))
    }

    func testParseCodexHooksTrustedReadsACRLFConfig() {
        // A CRLF "\r\n" is a single Swift Character, so a parser splitting on "\n"
        // sees the whole file as one line and matches nothing.
        let header = "[hooks.state.\"\(AgentIntegration.pluginID):hooks/hooks.json:stop:0:0\"]"
        XCTAssertTrue(AgentIntegration.parseCodexHooksTrusted("\(header)\r\ntrusted_hash = \"sha256:20cb\"\r\n"))
        XCTAssertFalse(AgentIntegration.parseCodexHooksTrusted("\(header)\r\nenabled = true\r\n"))
    }
}
