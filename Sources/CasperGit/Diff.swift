/// A structured diff of a working tree against a base tree. Plain value data —
/// no libgit2 handles escape here.
public struct GitDiff: Equatable, Sendable {
    /// Immutable so the line counts below, derived once in `init`, can never go
    /// stale — and so `Equatable` stays a function of `files` alone.
    public let files: [GitDiffFile]

    /// Total added lines across every hunk — the diff summary's "+" count.
    public let insertions: Int

    /// Total removed lines across every hunk — the diff summary's "−" count.
    public let deletions: Int

    public init(files: [GitDiffFile]) {
        self.files = files
        // Counted once here rather than on every read: the diff view re-reads both
        // counts on each SwiftUI body evaluation, and walking every file/hunk/line
        // per read made re-rendering a large diff O(lines) several times over.
        var insertions = 0
        var deletions = 0
        for file in files {
            for hunk in file.hunks {
                for line in hunk.lines {
                    switch line.kind {
                    case .addition: insertions += 1
                    case .deletion: deletions += 1
                    case .context: break
                    }
                }
            }
        }
        self.insertions = insertions
        self.deletions = deletions
    }
}

public struct GitDiffFile: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case added, deleted, modified, renamed, copied, typechange
        case conflicted, unreadable, unmodified
    }
    public let oldPath: String
    public let newPath: String
    public let status: Status
    public let isBinary: Bool
    public let hunks: [GitDiffHunk]
    /// Stable identity for a file across successive diff computations, and the path
    /// it is displayed under. Unique within a single diff.
    ///
    /// libgit2 fills `git_diff_delta.new_file.path` on every delta — a deletion
    /// carries the same path as `old_file.path`, the two only diverging for a rename
    /// (pinned by `DiffTests.testDeletedFileIsDeletion`) — so a diff read off a real
    /// repository never takes the `oldPath` branch. It stays as the defined answer for
    /// a directly constructed value with an empty `newPath`, which is what
    /// `DiffDocument`'s own title fallback expects.
    public var id: String { newPath.isEmpty ? oldPath : newPath }
    public init(
        oldPath: String, newPath: String, status: Status,
        isBinary: Bool, hunks: [GitDiffHunk]
    ) {
        self.oldPath = oldPath; self.newPath = newPath; self.status = status
        self.isBinary = isBinary; self.hunks = hunks
    }
}

public struct GitDiffHunk: Equatable, Sendable {
    public let header: String
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [GitDiffLine]
    public init(
        header: String, oldStart: Int, oldLines: Int,
        newStart: Int, newLines: Int, lines: [GitDiffLine]
    ) {
        self.header = header; self.oldStart = oldStart; self.oldLines = oldLines
        self.newStart = newStart; self.newLines = newLines; self.lines = lines
    }
}

public struct GitDiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case context, addition, deletion }
    public let kind: Kind
    public let content: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public init(
        kind: Kind, content: String, oldLineNumber: Int?, newLineNumber: Int?
    ) {
        self.kind = kind; self.content = content
        self.oldLineNumber = oldLineNumber; self.newLineNumber = newLineNumber
    }
}
