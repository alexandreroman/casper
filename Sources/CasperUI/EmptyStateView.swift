import SwiftUI

/// Shown when the session has no workspaces: the app name centred plus a way to
/// add the first folder.
struct EmptyStateView: View {
    var onAddFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Casper")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No workspace yet.")
                .foregroundStyle(.tertiary)
            Button("Add folder…", action: onAddFolder)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
