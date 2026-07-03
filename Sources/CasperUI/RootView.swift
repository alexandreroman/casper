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
///
/// The `NavigationSplitView` re-shows the title whenever the sidebar collapses,
/// so a `Coordinator` observes the window and re-hides it on every update.
private struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainActor.assumeIsolated { context.coordinator.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = .hidden
    }

    final class Coordinator {
        private var observer: NSObjectProtocol?

        @MainActor
        func attach(to window: NSWindow) {
            window.titleVisibility = .hidden
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, window.titleVisibility != .hidden else { return }
                    window.titleVisibility = .hidden
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
