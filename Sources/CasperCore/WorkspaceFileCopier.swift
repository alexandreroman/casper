import Darwin
import Foundation

/// Copies files matching name patterns from one worktree into another, used to
/// seed a newly created workspace with local files Git doesn't track (e.g. `.env`).
enum WorkspaceFileCopier {
    /// Patterns are matched against a file's last path component via `fnmatch(3)`,
    /// so a plain name like ".env" matches literally and a name containing
    /// `*`/`?`/`[...]` behaves as a shell glob.
    static let defaultPatterns: [String] = [".env", ".env.local"]

    /// Recursively copy every file under `sourceRoot` whose name matches one of
    /// `patterns` into the same relative location under `destinationRoot`,
    /// preserving the source file's POSIX permission bits. The `.git` directory is
    /// never descended into. Returns the relative paths copied; zero matches is not
    /// an error. Throws on the first copy failure (unreadable source, permission
    /// denied on destination, etc.) — callers that need atomicity must roll back
    /// their own side effects.
    @discardableResult
    static func copy(
        patterns: [String] = defaultPatterns,
        from sourceRoot: String, to destinationRoot: String
    ) throws -> [String] {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourceRoot)

        // Standardize once up front so relative paths are computed against a
        // path-normalized (`.`/`..`/redundant slashes resolved, but symlinks left
        // intact), trailing-slash-terminated source prefix.
        let sourceStd = URL(fileURLWithPath: sourceRoot, isDirectory: true).standardizedFileURL
        let sourcePath = sourceStd.path.hasSuffix("/") ? sourceStd.path : sourceStd.path + "/"

        guard let enumerator = fm.enumerator(
            at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            return []
        }

        var copiedRelativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            let isDirectory =
                (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if fileURL.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                }
                continue
            }

            let name = fileURL.lastPathComponent
            guard patterns.contains(where: { fnmatch($0, name, 0) == 0 }) else { continue }

            let fileStd = fileURL.standardizedFileURL
            let relativePath = String(fileStd.path.dropFirst(sourcePath.count))
            let destinationURL = URL(fileURLWithPath: destinationRoot)
                .appendingPathComponent(relativePath)

            try fm.createDirectory(
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: fileURL, to: destinationURL)

            if let permissions = try fm.attributesOfItem(atPath: fileURL.path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destinationURL.path)
            }

            copiedRelativePaths.append(relativePath)
        }
        return copiedRelativePaths
    }
}
