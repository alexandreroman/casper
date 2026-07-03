import Foundation

/// Derives a Space's display name.
public enum SpaceName {
    /// The last path segment of the remote URL without a `.git` suffix; falls
    /// back to `folderName` when there is no usable remote.
    public static func derive(remoteURL: String?, folderName: String) -> String {
        guard var s = remoteURL, !s.isEmpty else { return folderName }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let idx = s.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            s = String(s[s.index(after: idx)...])
        }
        return s.isEmpty ? folderName : s
    }
}
