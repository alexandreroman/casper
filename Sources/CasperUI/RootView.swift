import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .frame(minWidth: 220)
        } detail: {
            if let id = model.selectedWorkspaceID, let workspace = model.workspace(id: id) {
                WorkspaceDetailView(model: model, workspace: workspace)
            } else {
                EmptyStateView(onAddFolder: { model.presentAddFolderPanel() })
            }
        }
        .background(WindowConfigurator())
    }
}

/// Hides the hosting window's title text (the centered title in the title bar)
/// while keeping the title bar and toolbar. Applied per-window so it does not
/// depend on app-activation timing.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            view?.window?.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = .hidden
    }
}
