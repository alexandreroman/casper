import Foundation

/// Pure computation for keeping a line present in a repo's
/// `.git/info/exclude`.
public enum GitInfoExclude {
    /// The exclude line for Casper-managed worktrees.
    public static let casperEntry = ".casper/"

    /// The new file contents that guarantee `entry` is present, or nil when it
    /// already is (so the caller can skip the write). Preserves existing lines
    /// and ensures a trailing newline before appending.
    public static func ensuring(_ entry: String, in contents: String?) -> String? {
        let existing = contents ?? ""
        let present = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == entry }
        if present { return nil }
        var base = existing
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        return base + entry + "\n"
    }
}
