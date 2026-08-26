import Foundation

/// Derives a Space's display name.
public enum SpaceName {
    /// Hoisted out of `derive` so the set is built once, not on every call.
    private static let slash = CharacterSet(charactersIn: "/")

    /// The last path segment of the remote URL without a `.git` suffix; falls
    /// back to `folderName` when there is no usable remote.
    public static func derive(remoteURL: String?, folderName: String) -> String {
        guard var s = remoteURL, !s.isEmpty else { return folderName }
        // Trim before stripping `.git`, so a trailing slash cannot hide the
        // suffix (`.../casper.git/` must still derive `casper`).
        s = s.trimmingCharacters(in: slash)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if let idx = s.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            s = String(s[s.index(after: idx)...])
        }
        return s.isEmpty ? folderName : s
    }
}
