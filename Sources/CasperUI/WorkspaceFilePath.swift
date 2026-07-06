import Foundation

/// Resolves a user-supplied file argument against a workspace worktree, with
/// containment checking so a path cannot escape the worktree.
enum WorkspaceFilePath {
    /// Resolve `file` (absolute or relative to `worktree`) to a standardized
    /// absolute path, returning it ONLY when it lies inside `worktree`
    /// (lexically — `..` segments are collapsed first). Returns nil when the
    /// resolved path escapes the worktree.
    static func resolve(_ file: String, inWorktree worktree: String) -> String? {
        // `isDirectory: true` forces a trailing slash without touching the
        // filesystem, so `relativeTo:` resolution stays purely lexical — a
        // bare `URL(fileURLWithPath:)` probes disk to decide directory-ness and
        // would resolve a relative `file` against the worktree's PARENT when the
        // worktree path does not exist on disk.
        let wt = URL(fileURLWithPath: worktree, isDirectory: true).standardizedFileURL
        let target = (file.hasPrefix("/")
            ? URL(fileURLWithPath: file)
            : URL(fileURLWithPath: file, relativeTo: wt)).standardizedFileURL
        let wtPath = wt.path
        let tPath = target.path
        guard tPath == wtPath || tPath.hasPrefix(wtPath + "/") else { return nil }
        return tPath
    }

    /// The worktree-relative path (forward-slash, no leading slash) for an
    /// absolute path known to be inside `worktree` — this matches `GitDiffFile.id`.
    static func relative(_ absolutePath: String, toWorktree worktree: String) -> String {
        let wt = URL(fileURLWithPath: worktree).standardizedFileURL.path
        if absolutePath == wt { return "" }
        if absolutePath.hasPrefix(wt + "/") { return String(absolutePath.dropFirst(wt.count + 1)) }
        return absolutePath
    }
}
