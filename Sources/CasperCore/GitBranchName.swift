import Foundation

/// Sanitizes arbitrary user text into a valid Git branch name.
public enum GitBranchName {
    /// Lowercase, collapse whitespace to `-`, replace ref-forbidden characters,
    /// collapse repeated separators, and trim edge separators. Returns nil when
    /// the result would be empty or invalid.
    public static func sanitize(_ raw: String) -> String? {
        var s = raw.lowercased()
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let forbidden = Set("~^:?*[]\\")
        s = String(s.map { forbidden.contains($0) ? "-" : $0 })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.replacingOccurrences(of: "..", with: ".")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        if s.hasSuffix(".lock") {
            s = String(s.dropLast(5))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        }
        if s.isEmpty || s == "@" { return nil }
        return s
    }
}
