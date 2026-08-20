import Foundation

/// Sanitizes arbitrary user text into a valid Git branch name.
public enum GitBranchName {
    /// Separators Git forbids at either edge of a ref name (it also forbids a
    /// trailing `.`). Built once: `sanitize` trims with it on every pass of its
    /// fixpoint loop.
    private static let edgeSeparators = CharacterSet(charactersIn: "-./")

    /// Lowercase, collapse whitespace to `-`, replace ref-forbidden characters
    /// (including ASCII control characters and the `@{` sequence), collapse
    /// repeated separators, then iterate Git's per-component leading-`.`/trailing-`.lock`
    /// rules together with the edge-separator trim to a fixpoint (each can re-expose
    /// work for the other). Returns nil when the result would be empty or invalid.
    /// The output is always a valid Git ref name or nil.
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

        // Collapse runs of a repeated separator to a single one. A character walk
        // does it in one pass: repeated `replacingOccurrences` passes would each
        // allocate a fresh string and still need looping, since one non-overlapping
        // pass leaves `--` in `---` and `..` in `...`.
        var squashed = ""
        squashed.reserveCapacity(s.count)
        for character in s {
            let isSeparator = character == "-" || character == "."
            if isSeparator, squashed.last == character { continue }
            squashed.append(character)
        }
        s = squashed

        // Apply the per-component normalization and the whole-string edge-trim to
        // a fixpoint. The two steps can re-expose work for each other: trimming a
        // trailing `-`/`.` can uncover a fresh `.lock` suffix (e.g. `foo.lock-` →
        // `foo.lock`), and stripping `.lock` can uncover a trailing separator, so a
        // single pass is not enough (`a.lock-.lock` needs several). Both steps only
        // ever REMOVE characters, so `s` strictly shrinks and the loop terminates
        // quickly.
        var previous: String
        repeat {
            previous = s

            // Per-component rule: no slash-separated component may begin with a
            // dot or end with `.lock`. Checking only the whole-string edges would
            // miss `foo.lock.lock`, `a.lock/b`, or `foo/.bar`.
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
            s = s.trimmingCharacters(in: edgeSeparators)
        } while s != previous

        if s.isEmpty || s == "@" { return nil }
        return s
    }
}
