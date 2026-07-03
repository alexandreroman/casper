import AppKit
import CasperCore
import CasperGhostty
import SwiftUI

/// Renders a single `Surface` (a tmux-style pane) and attaches the pane
/// context menu: four splits (each creating a new terminal), copy/paste, and
/// close. Surface identity anchors on `Surface.id`, so the persistent view
/// cache in `AppModel` keeps each PTY / web page alive across layout churn.
struct SurfaceHostView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    let surface: Surface

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu { paneMenu }
    }

    @ViewBuilder
    private var content: some View {
        if let view = model.surfaceView(for: surface, in: workspace) {
            PersistentNSViewHost(view: view).id(surface.id)
        } else if case .terminal = surface.kind {
            Color.black  // runtime not ready yet
        } else if case .browser = surface.kind {
            BrowserSurfaceView(model: model, surface: surface)
        } else if case .diff = surface.kind {
            DiffSurfaceView(model: model, workspace: workspace)
        } else {
            ContentUnavailableView(
                "Unsupported surface", systemImage: "rectangle.dashed",
                description: Text("This surface kind isn't supported yet."))
        }
    }

    /// The pane context menu. Splits always create a terminal. Copy/Paste are
    /// dispatched down the responder chain to the focused `GhosttySurfaceView`
    /// (see `SurfaceHostView.dispatch`), so on a browser/diff pane they act on
    /// the focused terminal rather than the pane itself.
    @ViewBuilder
    private var paneMenu: some View {
        Button { model.applySplit(from: surface.id, direction: .up) } label: {
            Label("Split up", systemImage: "rectangle.tophalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .down) } label: {
            Label("Split down", systemImage: "rectangle.bottomhalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .left) } label: {
            Label("Split left", systemImage: "rectangle.lefthalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .right) } label: {
            Label("Split right", systemImage: "rectangle.righthalf.filled")
        }
        Divider()
        Button { dispatch(#selector(NSText.copy(_:))) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        Button { dispatch(#selector(NSText.paste(_:))) } label: {
            Label("Paste", systemImage: "clipboard")
        }
        .keyboardShortcut("v", modifiers: .command)
        Divider()
        Button(role: .destructive) { model.applyCloseSurface(surface.id) } label: {
            Label("Close pane", systemImage: "xmark")
        }
        .keyboardShortcut("w", modifiers: .command)
    }

    /// Fire an Edit-menu selector through the responder chain, reaching the
    /// focused `GhosttySurfaceView` (mirrors `GhosttyMenu`'s nil-target items).
    private func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
