import Foundation

/// A structured diff of a working tree against a base tree. Plain value data —
/// no libgit2 handles escape here.
public struct GitDiff: Equatable, Sendable {
    public var files: [GitDiffFile]
    public init(files: [GitDiffFile]) { self.files = files }

    /// Total added lines across every hunk — the diff summary's "+" count.
    public var insertions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .addition }.count
    }

    /// Total removed lines across every hunk — the diff summary's "−" count.
    public var deletions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .deletion }.count
    }
}

public struct GitDiffFile: Equatable, Sendable {
    public enum Status: String, Sendable {
        case added, deleted, modified, renamed, copied, typechange, unmodified
    }
    public var oldPath: String
    public var newPath: String
    public var status: Status
    public var isBinary: Bool
    public var hunks: [GitDiffHunk]
    public init(
        oldPath: String, newPath: String, status: Status,
        isBinary: Bool, hunks: [GitDiffHunk]
    ) {
        self.oldPath = oldPath; self.newPath = newPath; self.status = status
        self.isBinary = isBinary; self.hunks = hunks
    }
}

public struct GitDiffHunk: Equatable, Sendable {
    public var header: String
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [GitDiffLine]
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
    public var kind: Kind
    public var content: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public init(
        kind: Kind, content: String, oldLineNumber: Int?, newLineNumber: Int?
    ) {
        self.kind = kind; self.content = content
        self.oldLineNumber = oldLineNumber; self.newLineNumber = newLineNumber
    }
}
