import Foundation

/// Not `Sendable`: holds shared mutable `JSONEncoder`/`JSONDecoder` instances.
/// Thread-safety relies on caller confinement — all access must happen on the
/// main actor (its sole owner, `AppModel`, is main-actor-isolated).
public final class SessionStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Casper", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json", isDirectory: false)
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

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }
}
