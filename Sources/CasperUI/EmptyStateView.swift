import SwiftUI

/// Shown full-window whenever the session has no Spaces (`RootView` gates on
/// `spaces.isEmpty`): first launch, or after the user has removed every Space.
/// Copy stays evergreen/instructional — a returning user hits the same screen.
struct EmptyStateView: View {
    var onAddFolder: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, height: 76)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Casper")
                    .font(.system(size: 30, weight: .semibold))
                Text("An agent-aware terminal workspace for every Git worktree.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(spacing: 6) {
                Button("Add Folder…", action: onAddFolder)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                Text("or press ⌘O")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 14) {
                OnboardingStep(
                    index: 1, systemImage: "folder.badge.plus", title: "Add a folder",
                    detail: "Adopt any repo — Casper groups it as a Space.", tint: .blue)
                OnboardingStep(
                    index: 2, systemImage: "arrow.triangle.branch", title: "Branch a worktree",
                    detail: "Each gets its own isolated terminal workspace.", tint: .green)
                OnboardingStep(
                    index: 3, systemImage: "sparkles", title: "Run your agent",
                    detail: "Live state, diff & browser preview alongside.", tint: .orange)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// One card in the onboarding strip: a numbered step with an icon, title, and a
/// one-line explanation. Fixed width so the three-card row stays centered.
private struct OnboardingStep: View {
    let index: Int
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint, in: Circle())
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
        .padding(14)
        .frame(width: 180, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
