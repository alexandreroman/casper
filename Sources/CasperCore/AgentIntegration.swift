import Foundation

// Pure, testable detection of the Casper agent integration.
//
// Casper bridges a coding agent's lifecycle to the `casper` CLI through a plugin
// the user installs. Casper never writes another agent's configuration — each
// agent ships its own installer for that — so all Casper does is *detect* what an
// installer left behind and remind the user when something is missing or stale.
// The probe is global: one answer per agent for the whole app, not per workspace.
//
// This file owns the policy half of that job: the agent catalogue, the status
// vocabulary, the version comparison, and one parser per agent for the evidence it
// leaves on disk. It performs no I/O whatsoever — every parser takes bytes or text
// the caller has already read, and nothing here touches `FileManager`, `Process` or
// `ProcessInfo`. A sibling file adds that layer on top. Keeping the policy
// side-effect-free turns every awkward case (a registry with a missing key, a
// config full of comments, a version string nobody can parse) into a plain unit
// test, which matters because all three input formats are owned by other projects
// and can change under us.

/// A coding agent Casper can integrate with.
public enum CodingAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex
    case opencode

    /// The identifier under which a dismissed reminder for this agent is
    /// persisted, in `Session.dismissedAgentReminders`.
    ///
    /// Deliberately independent of `rawValue`: these ids outlive the process in
    /// the user's `session.json`, so spelling them out here means renaming an
    /// enum case can never silently invalidate a dismissal the user already
    /// made. Changing a value in this switch does exactly that, and is the only
    /// way to.
    ///
    /// One standing constraint on the values: **no id may be spelled
    /// `"<another-id>-trust"`**. Casper keys an agent's hook-trust notice as its id
    /// plus a `-trust` suffix, and retires action-needed dismissals by subtracting
    /// plain ids from the dismissed set — so such an id would silently clear a trust
    /// notice the user dismissed on a different agent. A unit test pins this.
    public var reminderID: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    /// The name each project uses for itself. `opencode` is lowercase on purpose —
    /// that is the project's own styling, not a typo to be "fixed".
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        }
    }

    /// The agent's own CLI executable. Its absence is the signal that the user does
    /// not use this agent at all, which is the one case Casper stays silent about.
    public var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    /// Whether an integration that is fully installed can still be inert.
    ///
    /// Codex hashes non-managed command hooks and refuses to run them until the user
    /// reviews and approves them through `/hooks` in the Codex TUI. A Codex install
    /// can therefore be complete on disk and do absolutely nothing. Trust state is
    /// not observable from disk, so rather than guess, the UI always states the
    /// caveat for agents flagged here.
    ///
    /// This is a *presentation* flag on the agent and deliberately not a fifth
    /// `AgentIntegrationStatus` case: the status vocabulary describes what was found
    /// on disk and stays agent-neutral, while this describes how to word it.
    public var requiresHookTrust: Bool {
        self == .codex
    }

    /// Where to send the user to install or fix this agent's integration.
    public var documentationURL: URL {
        // Force-unwrapped: both operands are literals, so this cannot fail.
        URL(string: AgentIntegration.documentationBaseURL + documentationFragment)!
    }

    /// Anchor of this agent's section in the `casper-skills` README.
    private var documentationFragment: String {
        switch self {
        case .claudeCode: return "#claude-code"
        case .codex: return "#codex"
        case .opencode: return "#opencode"
        }
    }
}

/// What Casper found out about one agent's integration.
public enum AgentIntegrationStatus: Equatable, Sendable {
    /// The agent's own CLI is absent, so the user does not use this agent. The UI
    /// says *nothing at all* here — no warning, no hint, no row. Advertising an
    /// integration for a tool someone has not installed is pure noise.
    case notInstalled
    /// The agent's CLI is present but the Casper integration is not installed.
    case missing
    /// The integration is installed but older than `AgentIntegration.requiredPluginVersion`.
    case outdated(installed: String)
    /// The integration is installed and current. Nothing to report.
    case installed
}

/// Namespace for the integration constants and the pure parsers behind
/// `AgentIntegrationStatus`.
public enum AgentIntegration {

    // MARK: - Constants

    /// The identifier Claude Code and Codex register the Casper plugin under, as
    /// declared by the plugin's manifest in the `casper-skills` repository.
    public static let pluginID = "casper@casper"

    /// The identifier the plugin was registered under before its marketplace was
    /// renamed, still present in every pre-rename user's Claude Code registry.
    ///
    /// A Claude Code plugin id is `<plugin>@<marketplace>`, and the old
    /// marketplace declared `"name": "Casper"` — so this value is *deterministic*
    /// and shared by all those users, not a per-machine accident. Recognising it is
    /// what turns "you already have the integration, from the old marketplace" into
    /// `.outdated`, which points at update instructions, instead of `.missing`,
    /// which would tell the user to install something they demonstrably have.
    ///
    /// To be clear about the scale of what this covers: the plugin was never published
    /// under the old marketplace name, so this is **one pre-publication local dev
    /// install**, not migration support for a population of users. Nothing here implies
    /// an obligation to keep migrating old ids — the branch is kept because it is three
    /// lines and turns a confidently wrong "install this" into the right answer.
    ///
    /// **This value differs from `pluginID` by case alone** — `casper@Casper` versus
    /// `casper@casper`. That is safe today because both sides of every lookup are
    /// case-sensitive: JSON object keys are, and so is Swift's `==` on `String`. Any
    /// future move to case-insensitive matching (`caseInsensitiveCompare`,
    /// `lowercased()`, a case-folding dictionary) would silently collapse the two ids
    /// into one, and with them the only signal that tells a pre-rename install apart
    /// from a current one. A unit test pins that they stay distinct-but-case-equal.
    public static let legacyPluginID = "casper@Casper"

    /// The plugin version Casper requires — the single place to change it.
    ///
    /// It must track the version the `casper` plugin declares in its own manifest.
    /// The comparison is `installed < required ⇒ outdated`, deliberately `<` and not
    /// `!=`: a user whose plugin is *ahead* of this Casper build is simply current,
    /// so shipping a plugin release never forces a Casper release just to stop
    /// Casper nagging everyone who upgraded promptly.
    public static let requiredPluginVersion = "0.2.0"

    /// Base of the integration documentation; `CodingAgent` appends its own anchor.
    public static let documentationBaseURL = "https://github.com/alexandreroman/casper-skills"

    /// npm package name of the opencode plugin, as written in an opencode config's
    /// top-level `plugin` array.
    public static let opencodePackageName = "casper-skills"

    /// File name of an opencode plugin installed locally. The plugin is plain
    /// JavaScript with no build step, so this is the file as shipped.
    public static let opencodePluginFileName = "casper.js"

    /// Directories, relative to the user's home, where an installed opencode plugin
    /// file can live. opencode's loader globs `{plugin,plugins}/*.{ts,js}`, so both
    /// spellings are valid and both occur in the wild — the I/O layer must look in
    /// each. Paths are relative because resolving the home directory is I/O.
    public static let opencodePluginDirectories = [
        ".config/opencode/plugin",
        ".config/opencode/plugins",
    ]

    // MARK: - Version comparison

    /// Whether `installed` is older than `required`.
    ///
    /// Components are compared numerically, one dotted component at a time, with a
    /// missing component treated as zero: `0.2` equals `0.2.0`, and `0.10.0` is
    /// newer than `0.9.0` — which a plain string comparison gets backwards.
    ///
    /// Anything that does not parse is reported as *not* outdated. That covers the
    /// literal `"unknown"`, which Claude Code records for a plugin whose manifest
    /// omits `version` and which genuinely appears in real registry files, and it
    /// covers pre-release suffixes and outright garbage. A version Casper cannot
    /// understand is not evidence of a stale install, and a false "update your
    /// plugin" nag costs more trust than a missed one.
    public static func isOutdated(installed: String, required: String) -> Bool {
        guard let installedComponents = versionComponents(installed),
              let requiredComponents = versionComponents(required)
        else {
            return false
        }
        return compare(installedComponents, requiredComponents) == .orderedAscending
    }

    /// Splits a dotted numeric version into its components, or nil when the string
    /// is empty or any component is not a plain non-negative number.
    private static func versionComponents(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        return components
    }

    /// The newest of several version strings that describe the *same* install, or
    /// nil when there are none.
    ///
    /// Every agent reports its installed version as an unordered set of candidates —
    /// one Claude registry record per scope, one Codex cache directory per
    /// marketplace — so picking any candidate but the highest turns "installed from
    /// two places, one of them stale" into a false `.outdated` nag. When nothing
    /// parses as a version, the lexicographically last candidate is returned
    /// verbatim, which keeps the status at "installed": `isOutdated` refuses to nag
    /// on a version it cannot read.
    private static func highestVersion(among candidates: [String]) -> String? {
        let parsed = candidates.compactMap { candidate -> (name: String, components: [Int])? in
            guard let components = versionComponents(candidate) else { return nil }
            return (candidate, components)
        }
        if let highest = parsed.max(by: { compare($0.components, $1.components) == .orderedAscending }) {
            return highest.name
        }
        return candidates.max()
    }

    /// Component-wise comparison, zero-filling the shorter side.
    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Claude Code

    /// A Casper plugin registration found in Claude Code's plugin registry.
    ///
    /// Carries which id matched as well as the version, because the two answers lead
    /// to different advice: a legacy registration has to move to the new
    /// marketplace whatever version it holds, while a current one is judged on its
    /// version alone.
    public struct ClaudePluginRegistration: Equatable, Sendable {
        /// The highest version recorded across the matched id's install records.
        public let version: String
        /// Whether the match came from `legacyPluginID` rather than `pluginID`.
        public let usesLegacyPluginID: Bool

        public init(version: String, usesLegacyPluginID: Bool) {
            self.version = version
            self.usesLegacyPluginID = usesLegacyPluginID
        }
    }

    /// Reads the installed plugin registration out of Claude Code's plugin registry
    /// (`~/.claude/plugins/installed_plugins.json`), or nil when neither the current
    /// nor the legacy plugin id is registered there.
    ///
    /// The verified shape (the file's own `"version": 2`) maps each plugin id to an
    /// **array** of install records, one per scope:
    ///
    /// ```json
    /// {"version": 2,
    ///  "plugins": {"casper@casper": [
    ///    {"scope": "user", "installPath": "…", "version": "0.2.0",
    ///     "installedAt": "…", "lastUpdated": "…"}]}}
    /// ```
    ///
    /// The **highest** version across the records wins, using the same numeric
    /// comparison as the Codex cache: the records are unordered, so a stale
    /// project-scope entry sitting ahead of a current user-scope one would otherwise
    /// produce an "update your plugin" nag at the moment the user is already current.
    /// A recorded `"unknown"` is returned verbatim when nothing parses —
    /// `isOutdated` is the one place that decides what an unparseable version means.
    ///
    /// Both ids are looked up, `pluginID` first, and the reported version always
    /// comes from the id that matched — versions are never mixed across ids, since
    /// the two registrations are separate installs.
    ///
    /// `JSONSerialization` rather than `Codable` on purpose: the schema is loose,
    /// partly untyped and owned by another project, so every unexpected shape has to
    /// degrade to nil rather than throw.
    public static func parseClaudeRegistry(
        _ data: Data,
        pluginID: String = AgentIntegration.pluginID,
        legacyPluginID: String = AgentIntegration.legacyPluginID
    ) -> ClaudePluginRegistration? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any]
        else {
            return nil
        }

        // The current id is consulted first, and a match there ends the search: a
        // user who has migrated but never cleaned up the old registration is
        // current, not outdated, and must not be nagged for a leftover record.
        if let version = highestRecordedVersion(in: plugins, for: pluginID) {
            return ClaudePluginRegistration(version: version, usesLegacyPluginID: false)
        }
        if let version = highestRecordedVersion(in: plugins, for: legacyPluginID) {
            return ClaudePluginRegistration(version: version, usesLegacyPluginID: true)
        }
        return nil
    }

    /// The highest version across the install records filed under one plugin id, or
    /// nil when the id is absent or none of its records carry a usable version.
    private static func highestRecordedVersion(in plugins: [String: Any], for pluginID: String) -> String? {
        guard let records = plugins[pluginID] as? [Any] else { return nil }
        let versions = records.compactMap { ($0 as? [String: Any])?["version"] as? String }
        return highestVersion(among: versions)
    }

    /// Whether Claude Code's settings leave the plugin enabled.
    ///
    /// The input is `~/.claude/settings.json`, where enablement is recorded
    /// separately from installation:
    ///
    /// ```json
    /// {"enabledPlugins": {"casper@casper": false}}
    /// ```
    ///
    /// Only an explicit `false` means disabled. An **absent** key means enabled: the
    /// map carries only the plugins whose global state the user has actually
    /// touched, and enablement can also be set per project, so a missing key here is
    /// evidence of nothing. Unreadable or unexpected JSON degrades to `true` for the
    /// same reason — nothing in this parser may manufacture a "your integration is
    /// missing" nag out of a file it failed to understand.
    ///
    /// This is the Claude-side counterpart of `parseCodexDisabled`, in the polarity
    /// each tool writes: Codex records a disabled plugin, Claude Code records an
    /// enablement flag.
    ///
    /// `JSONSerialization` bridges JSON numbers to `NSNumber`, which casts to `Bool`,
    /// so a hand-written `0` reads as disabled and `1` as enabled. That is left as
    /// is: someone who types `0` there means false. A *quoted* `"false"` is not a
    /// boolean and reads as enabled — the safe direction for a value nobody meant as
    /// a flag.
    public static func parseClaudeEnabled(
        _ data: Data,
        pluginID: String = AgentIntegration.pluginID,
        legacyPluginID: String = AgentIntegration.legacyPluginID
    ) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabledPlugins = root["enabledPlugins"] as? [String: Any]
        else {
            return true
        }

        // Both ids are consulted, because a pre-rename user's key here is the legacy
        // one: an explicit `false` under either spelling switches the same
        // integration off, and reading only the current id would report a plugin the
        // user has deliberately disabled as live.
        for identifier in [pluginID, legacyPluginID] {
            if let enabled = enabledPlugins[identifier] as? Bool, !enabled { return false }
        }
        return true
    }

    // MARK: - opencode

    /// Whether an opencode config registers the Casper plugin.
    ///
    /// The input is `~/.config/opencode/opencode.json` or `.jsonc`. Despite the
    /// `.json` name the format is **JSONC**: `//` and `/* */` comments are legal and
    /// real user files contain them, so handing the text straight to
    /// `JSONSerialization` fails. Comments are stripped first, taking care never to
    /// cut a `//` that lives inside a string literal — opencode's own default config
    /// carries `"$schema": "https://opencode.ai/config.json"`, so that case is
    /// routine rather than theoretical.
    ///
    /// A match is a top-level `plugin` entry that names the npm package
    /// (`casper-skills`, with or without an `@version` suffix) or points at a local
    /// `casper.js`. Anchoring to those two forms, rather than to a bare `casper`
    /// substring, keeps an unrelated plugin that merely has `casper` in its name from
    /// being mistaken for the integration.
    ///
    /// When parsing fails, the string literals of the comment-stripped text are
    /// scanned instead of returning a hard `false`: a config Casper cannot parse is
    /// no reason to tell the user their plugin is missing. The fallback scans the
    /// *stripped* text, not the raw text, so a commented-out entry does not count as
    /// an install on this path either.
    public static func parseOpencodeConfig(_ text: String) -> Bool {
        let stripped = stripJSONComments(text)
        guard let root = (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) as? [String: Any] else {
            return quotedStrings(in: stripped).contains(where: isOpencodePluginEntry)
        }

        let entries = (root["plugin"] as? [Any])?.compactMap { $0 as? String } ?? []
        return entries.contains(where: isOpencodePluginEntry)
    }

    /// Reads the version an installed opencode plugin file declares.
    ///
    /// The plugin is plain JavaScript with no build step, and carries on its own
    /// line:
    ///
    /// ```js
    /// export const CASPER_PLUGIN_VERSION = "0.2.0"
    /// ```
    ///
    /// Returns nil when the constant is absent — an older plugin file that predates
    /// it, or one whose declaration does not use double quotes. The caller must read
    /// nil as "present, version unreadable" and leave the user alone; it is never a
    /// reason to nag.
    ///
    /// Commented-out lines are skipped so a documented example cannot outrank the
    /// real declaration. That check is a line-level heuristic (`//`, `/*` and `*`
    /// prefixes), not a JavaScript parser — enough for a file Casper's own installer
    /// writes, and cheap.
    public static func parseOpencodeVersion(_ source: String) -> String? {
        // Both edges of the identifier are anchored: `\b` alone rejects a suffixed
        // namesake (`CASPER_PLUGIN_VERSION_LEGACY`) but happily matches inside a
        // prefixed one (`PREV_CASPER_PLUGIN_VERSION`), reading a neighbouring
        // constant's value as the plugin's. A leading `(?<!…)` would say this more
        // directly, but Swift's regex engine does not support lookbehind.
        let declaration = /(?:^|[^A-Za-z0-9_])CASPER_PLUGIN_VERSION\b\s*=\s*"([^"]+)"/
        // `\.isNewline` rather than "\n": a CRLF "\r\n" is a single Swift Character
        // and unequal to "\n", so splitting on the literal would treat a CRLF file as
        // one line and let its first comment suppress the whole file.
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }
            if let match = trimmed.firstMatch(of: declaration) { return String(match.1) }
        }
        return nil
    }

    /// True for an opencode `plugin[]` entry that refers to the Casper plugin.
    ///
    /// Two forms count, and each is matched whole rather than by substring, because
    /// `casper` is a common enough word that a loose match mistakes someone else's
    /// plugin for the integration: `@evil/casper-skills-fork` merely *contains* the
    /// package name, and `./plugin/notcasper.js` merely *ends with* the file name.
    private static func isOpencodePluginEntry(_ entry: String) -> Bool {
        let lowercased = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // The npm form: the package name, optionally followed by `@<version>`.
        let packageName = String(lowercased.prefix { $0 != "@" })
        if packageName == opencodePackageName { return true }

        // The local-file form: the plugin file has to be the entry's own last path
        // component, not just the tail of some longer file name.
        return lowercased.split(separator: "/").last.map(String.init) == opencodePluginFileName
    }

    /// Removes `//` line comments and `/* */` block comments from JSONC text.
    ///
    /// String literals are left untouched (the `//` in `"https://…"` is data, not a
    /// comment) and backslash escapes are honoured so an escaped quote cannot end a
    /// string early. Comment bodies are dropped rather than blanked; the result only
    /// has to be valid JSON, not to keep its original offsets.
    private static func stripJSONComments(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)

        var index = 0
        var insideString = false
        while index < characters.count {
            let character = characters[index]

            if insideString {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    // The escape consumes the next character, so `\"` cannot close the string.
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { insideString = false }
                index += 1
                continue
            }

            if character == "\"" {
                insideString = true
                output.append(character)
                index += 1
                continue
            }

            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", next == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                // Clamped so an unterminated block comment simply runs to the end.
                index = min(index + 2, characters.count)
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    /// Extracts the contents of every double-quoted string literal in `text`. Used
    /// only on the fallback path, where the input is by definition not valid JSON,
    /// so a lenient scan is all that is available.
    private static func quotedStrings(in text: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var insideString = false
        var escaped = false

        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if insideString, character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                if insideString {
                    literals.append(current)
                    current.removeAll()
                }
                insideString.toggle()
                continue
            }
            if insideString {
                current.append(character)
            }
        }
        return literals
    }

    // MARK: - Codex

    /// Picks the installed plugin version out of the directory names found in Codex's
    /// plugin cache.
    ///
    /// Codex installs land in
    /// `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/`, so the caller
    /// passes the *version-level* directory names — from every marketplace at once,
    /// since the same plugin can be installed from more than one — and the highest
    /// one wins, using the same numeric comparison as `isOutdated` (so `0.10.0` beats
    /// `0.9.0`). An empty list is nil. The version comes only from this path
    /// segment: the plugin
    /// repository deliberately ships a single `.claude-plugin/plugin.json` and relies
    /// on Codex's discovery order falling through to it, so probing by manifest file
    /// name would miss the install entirely.
    ///
    /// NOTE: this layout comes from Codex's published documentation and has **not**
    /// been verified against a real install — no Codex was available on either side
    /// of this work. It is the parser most likely to need correcting, and this
    /// comment is the marker for whoever first gets a real Codex to check it against.
    /// Dot-prefixed names are dropped first: an uninstall that leaves the directory
    /// behind with nothing but a Finder-written `.DS_Store` in it must read as an
    /// absent install, not as one whose version is `.DS_Store`. A visible name that
    /// is merely unparseable still counts as installed — Claude Code's registry
    /// records real install paths ending in `/unknown`, so an unrecognised shape is
    /// a normal install, while a hidden file is never one.
    public static func parseCodexCacheEntries(_ directoryNames: [String]) -> String? {
        highestVersion(among: directoryNames.filter { !$0.hasPrefix(".") })
    }

    /// Whether Codex's config marks the plugin as disabled.
    ///
    /// Codex records a disabled plugin as a TOML section carrying `enabled = false`:
    ///
    /// ```toml
    /// [plugins."casper@casper"]
    /// enabled = false
    /// ```
    ///
    /// An absent section means enabled, so the scan is targeted: find that section
    /// header, then look for `enabled = false` before the next `[` header.
    ///
    /// This is deliberately not a TOML parser. The project's dependency policy is
    /// strict (see CLAUDE.md) and a TOML library to read one boolean does not earn
    /// its place, while a five-line scan does. The limitations are real and accepted,
    /// and all miss in the same safe direction — an unseen `enabled = false` reads as
    /// enabled, never the reverse:
    ///
    /// - an inline table
    ///   (`plugins = { "casper@casper" = { enabled = false } }`);
    /// - any value that is not a bare `false`;
    /// - a multi-line array inside the section, whose continuation lines start with
    ///   `[` and are taken for a section header, ending the scan early.
    ///
    /// None of these is the form Codex writes.
    public static func parseCodexDisabled(
        _ configTOML: String,
        pluginID: String = AgentIntegration.pluginID
    ) -> Bool {
        // Both spellings of the header: Codex quotes the id (it contains a `@`), but
        // a hand-edited config may not.
        let headers = [#"[plugins."\#(pluginID)"]"#, "[plugins.\(pluginID)]"]

        var insideSection = false
        // Split on any newline, never on the literal "\n": Swift's `Character` is a
        // grapheme cluster, so a CRLF "\r\n" is *one* Character and unequal to "\n" —
        // splitting on "\n" hands a CRLF config back as a single line and matches
        // nothing. `.whitespacesAndNewlines` for the same reason: `.whitespaces`
        // excludes `\r`, which would otherwise cling to a lone-CR file's values.
        for line in configTOML.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                insideSection = headers.contains(trimmed)
                continue
            }
            if insideSection, isEnabledFalse(trimmed) { return true }
        }
        return false
    }

    /// True for a TOML `enabled = false` assignment, tolerant of spacing and of a
    /// trailing `#` comment.
    private static func isEnabledFalse(_ line: String) -> Bool {
        let statement = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = statement.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "enabled"
            && parts[1].trimmingCharacters(in: .whitespacesAndNewlines) == "false"
    }
}
