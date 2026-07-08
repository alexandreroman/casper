import Foundation

/// Identifies a Casper "session": an isolated instance whose layout file and
/// sockets are suffixed with the session name so a second instance (typically a
/// dev/test build) can run alongside the user's real one. A `nil` name is the
/// default (unnamed) session, whose paths are byte-for-byte the historical ones.
public struct SessionIdentity: Sendable, Equatable {
    public let name: String?

    /// The default (unnamed) session.
    public static let `default` = SessionIdentity(unchecked: nil)

    private init(unchecked name: String?) { self.name = name }

    /// A `nil` name is always valid (default session). A non-nil name must be
    /// non-empty, at most 32 characters, and drawn from `[A-Za-z0-9._-]` — it
    /// becomes part of a filename and a Unix socket path (macOS caps
    /// `sun_path` at ~104 bytes). Returns `nil` for an invalid non-nil name.
    public init?(name: String?) {
        if let name, !SessionIdentity.isValid(name) { return nil }
        self.name = name
    }

    public static func isValid(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `""` for the default session, `"-<name>"` otherwise. The single source of
    /// the `-<name>` convention, reused by every derived path.
    public var pathSuffix: String { name.map { "-\($0)" } ?? "" }

    public var layoutFileName: String { "session\(pathSuffix).json" }

    public func controlSocketPath(temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        (temporaryDirectory as NSString).appendingPathComponent("casper-control\(pathSuffix).sock")
    }

    public var debugSocketPath: String { "/tmp/casper-debug\(pathSuffix).sock" }

    public enum ParseError: Error, Equatable {
        case missingValue
        case invalidName(String)
    }

    /// Parse an optional `--session <name>` / `--session=<name>` from GUI launch
    /// arguments. Debug builds only — release builds always return `.default`,
    /// ignoring any `--session` argument. No `--session` → the default session.
    /// `--session` with no value throws `.missingValue`; a present-but-invalid
    /// name throws `.invalidName`.
    public static func parse(arguments: [String]) throws -> SessionIdentity {
#if DEBUG
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == "--session" {
                guard let value = iterator.next() else { throw ParseError.missingValue }
                guard let id = SessionIdentity(name: value) else { throw ParseError.invalidName(value) }
                return id
            }
            if arg.hasPrefix("--session=") {
                let value = String(arg.dropFirst("--session=".count))
                guard let id = SessionIdentity(name: value) else { throw ParseError.invalidName(value) }
                return id
            }
        }
#endif
        return .default
    }
}
