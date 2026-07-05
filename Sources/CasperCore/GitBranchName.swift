import Foundation

/// Sanitizes arbitrary user text into a valid Git branch name.
public enum GitBranchName {
    /// Lowercase, collapse whitespace to `-`, replace ref-forbidden characters
    /// (including ASCII control characters and the `@{` sequence), collapse
    /// repeated separators, apply Git's per-component leading-`.`/trailing-`.lock`
    /// rules, and trim edge separators. Returns nil when the result would be empty
    /// or invalid. The output is always a valid Git ref name or nil.
    public static func sanitize(_ raw: String) -> String? {
        var s = raw.lowercased()
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")

        // Replace characters Git forbids in a ref name — plus ASCII control
        // characters (< 0x20) and DEL (0x7F), which Git rejects too — with the
        // separator.
        let forbidden = Set("~^:?*[]\\")
        s = String(s.map { character in
            if forbidden.contains(character) { return "-" }
            if let ascii = character.asciiValue, ascii < 0x20 || ascii == 0x7F { return "-" }
            return character
        })

        // Git forbids the `@{` sequence. Replacing it with `-` cannot recreate
        // the sequence, so a single pass suffices.
        s = s.replacingOccurrences(of: "@{", with: "-")

        // Collapse repeated separators. Both use a loop because a single
        // non-overlapping pass would leave `--` in `---` and `..` in `...`.
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        while s.contains("..") { s = s.replacingOccurrences(of: "..", with: ".") }

        // Apply Git's per-component rules: no slash-separated component may begin
        // with a dot or end with `.lock`. Checking only the whole-string edges
        // misses `foo.lock.lock`, `a.lock/b`, or `foo/.bar`.
        s = s.split(separator: "/", omittingEmptySubsequences: true)
            .map { component -> Substring in
                var c = component
                while c.hasPrefix(".") { c = c.dropFirst() }
                while c.hasSuffix(".lock") { c = c.dropLast(5) }
                return c
            }
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        // Trim any separator left at the whole-string edges (leading/trailing
        // `-`, `.`, or `/`; Git also forbids a trailing `.`).
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))

        if s.isEmpty || s == "@" { return nil }
        return s
    }
}
