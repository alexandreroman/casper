import SwiftUI

/// The title-bar label naming the selected workspace: a Git-branch glyph plus
/// "Space / branch" for a Git-backed Space, a folder glyph plus the Space name
/// for a degenerate one.
///
/// It ships inside the title-bar row, which is routinely proposed far less than
/// its ideal width. A label with no line limit answers such a proposal by
/// *wrapping* — mid-word, even — and pushes the title bar open, so
/// `.lineLimit(1)` is the rule that keeps it on one line whatever it is offered.
///
/// Which `form` to draw is the ROW's decision, not this label's: dropping the
/// Space name is one rung of the row's single ordered ladder, ranked against the
/// diff badge and the action chips (see `WorkspaceTitleBarRow`). A label that
/// chose for itself would be a second ladder deciding independently, and two
/// ladders cannot be ordered against each other — the row's degradation stops
/// being monotone, and shrinking the window hands room BACK to whatever the other
/// ladder just released.
///
/// Within a form the branch still middle-truncates on its own. That is `Text`
/// answering a proposal, not a second ladder: it changes what the same rung looks
/// like, never which rung is chosen.
struct WorkspaceTitleLabel: View {
    /// How much of the title to draw. A non-Git Space has no Space/branch split to
    /// collapse, so both forms render its folder name.
    enum Form {
        /// The Space name for context, then the branch.
        case spaceAndBranch
        /// The branch alone — identity without context.
        case branchOnly
    }

    let isGitRepo: Bool
    let spaceName: String
    let branchLabel: String
    let form: Form

    /// Gap between the glyph and the text runs, shared by every candidate so the
    /// label doesn't visibly re-space as it degrades.
    private static let spacing: CGFloat = 7

    var body: some View {
        // Mirror WorkspaceRow: git-branch glyph + "Space / branch" for a
        // Git-backed Space, folder glyph + Space name for a degenerate one.
        Group {
            switch (isGitRepo, form) {
            case (true, .spaceAndBranch): spaceAndBranch
            // The branch alone, middle-truncated so both ends of a long name (its
            // prefix and the part that usually distinguishes it) survive.
            case (true, .branchOnly): glyphTitle(.gitBranch, branchLabel)
            // A Space with no Git repository behind it has no branch to fall back
            // to, so its name is the identity and simply truncates.
            case (false, _): glyphTitle(.fileDirectory, spaceName)
            }
        }
        .lineLimit(1)
    }

    /// The Space name for context, then the branch in bold.
    private var spaceAndBranch: some View {
        HStack(spacing: Self.spacing) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(spaceName).foregroundStyle(.secondary)
            Text("/").foregroundStyle(.secondary)
            Text(branchLabel)
                .fontWeight(.bold)
        }
    }

    /// A glyph and the one bold run that carries the workspace's identity, middle-
    /// truncated so both ends of a long name survive. The shape both single-run
    /// forms take — which glyph and which text is the caller's choice.
    private func glyphTitle(_ name: Octicon.Name, _ text: String) -> some View {
        HStack(spacing: Self.spacing) {
            Octicon(name).foregroundStyle(.secondary)
            Text(text)
                .fontWeight(.bold)
                .truncationMode(.middle)
        }
    }
}
