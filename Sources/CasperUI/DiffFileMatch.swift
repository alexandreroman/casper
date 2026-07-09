import CasperGit
import Foundation

/// Resolve a user-supplied file argument to a diff file's id (see
/// `GitDiffFile.id`). Tries, in order: exact id match, a path-suffix match
/// (the id ends with "/<target>" or equals it), then a basename match.
/// Returns nil when nothing matches.
enum DiffFileMatch {
    static func match(_ target: String, in files: [GitDiffFile]) -> String? {
        if let exact = files.first(where: { $0.id == target }) { return exact.id }
        if let suffix = files.first(where: { $0.id.hasSuffix("/" + target) }) { return suffix.id }
        let base = (target as NSString).lastPathComponent
        if let byBase = files.first(where: { ($0.id as NSString).lastPathComponent == base }) { return byBase.id }
        return nil
    }
}
