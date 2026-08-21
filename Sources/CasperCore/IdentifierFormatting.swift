import Foundation

public extension UUID {
    /// Casper's canonical external string form for an id: lowercase.
    ///
    /// Every id Casper emits at a boundary — the injected `CASPER_WORKSPACE_ID`,
    /// control-channel JSON, notification and drag payloads — goes through this
    /// property, so the whole surface reads uniformly. `UUID.uuidString` renders
    /// uppercase, which is why the plain property is never used at a boundary.
    ///
    /// Matching stays **case-insensitive** (see `ControlTargeting`, and
    /// `UUID(uuidString:)` itself), so an uppercase id minted by an older build —
    /// or typed by a user — still resolves.
    ///
    /// Persisted state is unaffected: `session.json` keeps Swift's native
    /// `Codable` UUID encoding.
    var casperID: String { uuidString.lowercased() }
}
