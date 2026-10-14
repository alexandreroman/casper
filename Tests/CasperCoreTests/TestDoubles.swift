import Foundation
@testable import CasperCore

/// A `Sendable` place for a `@Sendable` stub to record its calls. `@unchecked`
/// because the values are only ever touched under `lock` — the same discipline
/// `LoginShellPath`'s own storage uses.
final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Element] = []

    /// Everything recorded so far, in call order.
    var values: [Element] { lock.withLock { recorded } }

    func record(_ value: Element) {
        lock.withLock { recorded.append(value) }
    }
}

/// A genuine pre-rename Claude Code registry entry, as found on a real machine
/// that installed before the marketplace was renamed — `installPath` and
/// `gitCommitSha` included — so the legacy path is proved against the shape
/// Claude Code actually writes, not a tidied-up stand-in.
func legacyClaudeRegistry(version: String) -> String {
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
