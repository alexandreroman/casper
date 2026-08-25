import SwiftUI

/// The title-bar label naming the selected workspace: a Git-branch glyph plus
/// "Space / branch" for a Git-backed Space, a folder glyph plus the Space name
/// for a degenerate one.
///
/// It ships inside the leading toolbar group, which the toolbar routinely
/// proposes far less than its ideal width once the trailing chips have claimed
/// their share of a narrow window. A label with no line limit answers such a
/// proposal by *wrapping* — mid-word, even — and pushes the title bar open, so
/// `.lineLimit(1)` is the rule that keeps it on one line whatever it is offered.
/// `ViewThatFits` then makes the way down graceful: the Space name is context
/// and is dropped as a whole rather than truncated to an ellipsis stub, while
/// the branch is the workspace's identity and survives, middle-truncated only
/// once it no longer fits on its own.
struct WorkspaceTitleLabel: View {
    let isGitRepo: Bool
    let spaceName: String
    let branchLabel: String

    /// Gap between the glyph and the text runs, shared by every candidate so the
    /// label doesn't visibly re-space as it degrades.
    private static let spacing: CGFloat = 7

    var body: some View {
        // Mirror WorkspaceRow: git-branch glyph + "Space / branch" for a
        // Git-backed Space, folder glyph + Space name for a degenerate one.
        Group {
            if isGitRepo {
                ViewThatFits(in: .horizontal) {
                    spaceAndBranch
                    branchOnly
                }
            } else {
                folderName
            }
        }
        .lineLimit(1)
    }

    /// Full form: the Space name for context, then the branch in bold.
    private var spaceAndBranch: some View {
        HStack(spacing: Self.spacing) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(spaceName).foregroundStyle(.secondary)
            Text("/").foregroundStyle(.secondary)
            Text(branchLabel)
                .fontWeight(.bold)
        }
    }

    /// Compact fallback: the branch alone, middle-truncated so both ends of a
    /// long name (its prefix and the part that usually distinguishes it) survive.
    private var branchOnly: some View {
        HStack(spacing: Self.spacing) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(branchLabel)
                .fontWeight(.bold)
                .truncationMode(.middle)
        }
    }

    /// A Space with no Git repository behind it has no branch to fall back to,
    /// so its name is the identity and simply truncates.
    private var folderName: some View {
        HStack(spacing: Self.spacing) {
            Octicon(.fileDirectory).foregroundStyle(.secondary)
            Text(spaceName)
                .fontWeight(.bold)
                .truncationMode(.middle)
        }
    }
}
