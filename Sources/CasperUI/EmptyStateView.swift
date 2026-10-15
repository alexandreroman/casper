import AppKit
import SwiftUI

/// Shown full-window whenever the session has no Spaces (`RootView` gates on
/// `spaces.isEmpty`): first launch, or after the user has removed every Space.
/// Copy stays evergreen/instructional — a returning user hits the same screen.
///
/// It offers the same two ways in as the Space menu and the sidebar footer, in the
/// same order: create a Space from scratch, or adopt a folder that already exists.
/// Creating is the prominent one — a user with nothing open is likelier to be
/// starting something than to be looking for a repo they forgot to add.
struct EmptyStateView: View {
    let model: AppModel

    // Module-visible so `EmptyStateViewTests` derives the onboarding strip's width
    // from these rather than from copies of the numbers.
    /// Each onboarding card's fixed width.
    static let cardWidth: CGFloat = 200
    /// The gap between two onboarding cards.
    static let cardSpacing: CGFloat = 20
    /// The screen's own padding on every side.
    static let screenPadding: CGFloat = 48

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Casper")
                        .font(.system(size: 30, weight: .semibold))
                    Text("An agent-aware terminal workspace for every Git worktree.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ForEach(SpaceEntryCommand.allCases, id: \.self) { command in
                        entryButton(for: command)
                    }
                }
                // `fixedSize` keeps the hint on one line: it is a shortcut legend, and
                // wrapped over two lines it reads as prose. It stays far narrower than
                // the onboarding strip below, so it never widens the screen. The keys
                // spelled here are `SpaceEntryCommand.keyboardShortcut`'s; keep them in step.
                Text("⇧⌘N to create a Space · ⌘O to add a folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    // VoiceOver reads the ⌘ glyph itself, which announces as nothing
                    // useful, so the shortcuts are spelled out for it.
                    .accessibilityLabel("Shift Command N to create a Space, Command O to add a folder")
            }

            HStack(alignment: .top, spacing: Self.cardSpacing) {
                OnboardingStep(
                    index: 1, systemImage: "folder.badge.plus", title: "Start a Space",
                    detail: "Create a new repo, or adopt one you have.")
                OnboardingStep(
                    index: 2, systemImage: "arrow.triangle.branch", title: "Branch a worktree",
                    detail: "Each gets its own isolated terminal workspace.")
                OnboardingStep(
                    index: 3, systemImage: "sparkles", title: "Run your agent",
                    detail: "Live state, diff & browser preview alongside.")
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Self.screenPadding)
    }

    /// Creating is the prominent button, adopting merely bordered.
    @ViewBuilder
    private func entryButton(for command: SpaceEntryCommand) -> some View {
        let button = Button(command.title) { command.perform(model: model) }
            .controlSize(.large)
        if command == .create {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// One card in the onboarding strip: a numbered step with an icon, title, and a
/// one-line explanation. Fixed width so the three-card row stays centered.
private struct OnboardingStep: View {
    let index: Int
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: Circle())
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: EmptyStateView.cardWidth, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
