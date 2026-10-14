import CasperGit

// Shared by the diff suites: the diff-model values their documents are built
// from, so each suite spells out only what makes its own fixture distinctive.

/// One diff line: kind and content, then whichever line numbers it carries — an
/// addition has no old one, a deletion no new one.
func diffLine(_ kind: GitDiffLine.Kind, _ content: String, old: Int? = nil, new: Int? = nil) -> GitDiffLine {
    GitDiffLine(kind: kind, content: content, oldLineNumber: old, newLineNumber: new)
}

/// A file at `path` holding `lines` as a single hunk, whose header spells out
/// their count (`@@ -1,n +1,n @@`) so an expectation over the rendered text can
/// be written out in full. No lines means no hunk at all, as for a binary file.
func diffFile(
    _ path: String, lines: [GitDiffLine], status: GitDiffFile.Status = .modified, isBinary: Bool = false
) -> GitDiffFile {
    let hunks = lines.isEmpty ? [] : [GitDiffHunk(header: "@@ -1,\(lines.count) +1,\(lines.count) @@", lines: lines)]
    return GitDiffFile(oldPath: path, newPath: path, status: status, isBinary: isBinary, hunks: hunks)
}

/// `count` addition lines numbered from 1, each one's content built from its
/// number.
func additionLines(_ count: Int, content: (Int) -> String = { "line \($0)" }) -> [GitDiffLine] {
    (1...count).map { diffLine(.addition, content($0), new: $0) }
}
