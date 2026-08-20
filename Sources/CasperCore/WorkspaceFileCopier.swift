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

        // Standardize once up front and enumerate from that same standardized URL,
        // so the enumerated paths are guaranteed to carry the `sourcePath` prefix
        // the relative-path arithmetic below strips. Standardizing resolves
        // `.`/`..`/redundant slashes but leaves symlinks intact.
        let sourceStd = URL(fileURLWithPath: sourceRoot, isDirectory: true).standardizedFileURL
        let sourcePath = sourceStd.path.hasSuffix("/") ? sourceStd.path : sourceStd.path + "/"

        guard let enumerator = fm.enumerator(
            at: sourceStd, includingPropertiesForKeys: [.isDirectoryKey], options: []
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

            // Enumerating from `sourceStd` is expected to yield paths under
            // `sourcePath`, but verify it instead of assuming: dropping the prefix
            // length blindly would turn any standardization divergence into a
            // truncated relative path, which then gets joined onto
            // `destinationRoot` and writes outside the intended location.
            let fileStd = fileURL.standardizedFileURL
            guard fileStd.path.hasPrefix(sourcePath) else { continue }
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
