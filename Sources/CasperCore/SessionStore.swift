import Foundation

/// `@unchecked Sendable`: every stored field is immutable (`let`), and the only
/// entry point ever dispatched off the main actor, `write(_:)`, touches just
/// `fileURL`, `FileManager`, and `Data` — all thread-safe. `encode`/`load` use the
/// non-`Sendable` `JSONEncoder`/`JSONDecoder`, so they stay confined to the main
/// actor (their sole owner, `AppModel`, is main-actor-isolated); only `write(_:)`
/// runs on `AppModel`'s background save queue.
public final class SessionStore: @unchecked Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public static func defaultURL(fileManager: FileManager = .default,
                                  session: SessionIdentity = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Casper", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(session.layoutFileName, isDirectory: false)
    }

    /// Load the persisted session, self-healing when the file is unreadable as a
    /// `Session`. A missing file yields an empty `Session`. A genuine I/O read
    /// failure still propagates, so a transient error never destroys the file.
    /// A decode failure (truncated, hand-edited, or schema-incompatible file) is
    /// recovered from: the offending file is moved aside to a sibling
    /// `session.json.corrupt` backup for diagnostics and an empty `Session` is
    /// returned, so a stale on-disk format never blocks startup.
    public func load() throws -> Session {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Session()
        }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode(Session.self, from: data)
        } catch {
            CasperLog.app.error(
                "session.json is corrupt, backing it up and starting fresh: \(self.fileURL.path, privacy: .public)"
            )
            backUpCorruptFile()
            return Session()
        }
    }

    /// Move a corrupt session file aside so it is preserved for diagnostics.
    /// Best-effort: a backup failure must not block startup, so any error is
    /// swallowed and the caller still returns an empty `Session`.
    private func backUpCorruptFile() {
        let backupURL = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }

    /// Encode a session to JSON `Data`. Uses the non-`Sendable` `encoder`, so it
    /// must run on the main actor. Split from the disk `write(_:)` so the caller
    /// can encode on the main actor (where the state lives) and hand the resulting
    /// `Data` to a background queue for the blocking atomic write.
    public func encode(_ session: Session) throws -> Data {
        try encoder.encode(session)
    }

    /// Atomically write already-encoded session `Data` to disk, creating the
    /// containing directory if needed. Touches only `fileURL`, `FileManager`, and
    /// `Data`, all thread-safe, so it is the one method safe to call off the main
    /// actor (see the type's `@unchecked Sendable` note).
    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
