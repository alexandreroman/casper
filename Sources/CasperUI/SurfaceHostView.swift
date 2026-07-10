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

    /// Measured pane size, feeding the drop delegate's zone computation.
    @State private var paneSize: CGSize = .zero

    /// A pane can be dragged (and is a drop target) only when the workspace has
    /// more than one pane — a lone pane has nowhere to move.
    private var canDrag: Bool {
        LayoutTree.surfaceIDs(workspace.layout).count > 1
    }

    var body: some View {
        ZStack {
            content
            if canDrag {
                dragHandle
            }
            if canDrag, model.dropHoverTarget == surface.id, let zone = model.dropHoverZone {
                PaneDropHighlight(zone: zone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu { paneMenu }
        .background(sizeReader)
        .modifier(PaneDropTarget(enabled: canDrag, delegate: dropDelegate))
    }

    /// The AppKit "3-dot" grip: a centered rect (up to 200pt wide × 24pt tall)
    /// pinned to the pane's top edge, whose whole NSView bounds are the grab zone.
    private var dragHandle: some View {
        VStack(spacing: 0) {
            PaneDragHandle(
                surfaceID: surface.id,
                label: dragLabel,
                onDragStateChange: { active in active ? model.beginPaneDrag(surface.id) : model.endPaneDrag() })
                .frame(maxWidth: 200)
                .frame(height: 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Reads the live pane size into `paneSize` without affecting layout.
    private var sizeReader: some View {
        Color.clear
            .onGeometryChange(for: CGSize.self, of: \.size) { paneSize = $0 }
    }

    private var dropDelegate: PaneDropDelegate {
        PaneDropDelegate(
            targetID: surface.id,
            move: { [model, id = surface.id] sourceID, location, size in
                MainActor.assumeIsolated {
                    let zone = LayoutTree.dropZone(at: location, in: size)
                    model.moveSurface(sourceID, toTarget: id, zone: zone)
                }
            },
            size: $paneSize,
            setHover: { [model, id = surface.id] zone in model.setDropHover(target: id, zone: zone) },
            clearHover: { [model, id = surface.id] in model.clearDropHover(target: id) })
    }

    /// A short label for the drag preview: the terminal's directory name, the
    /// browser host, or a static tag for other surfaces.
    private var dragLabel: String {
        switch surface.kind {
        case .terminal(let cwd):
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? "Terminal" : name
        case .browser(let url):
            return url.host ?? "Browser"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let view = model.surfaceView(for: surface, in: workspace) {
            PersistentNSViewHost(view: view).id(surface.id)
        } else if case .terminal = surface.kind {
            Color.black  // runtime not ready yet
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
            Label("Split Up", systemImage: "rectangle.tophalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .down) } label: {
            Label("Split Down", systemImage: "rectangle.bottomhalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .left) } label: {
            Label("Split Left", systemImage: "rectangle.lefthalf.filled")
        }
        Button { model.applySplit(from: surface.id, direction: .right) } label: {
            Label("Split Right", systemImage: "rectangle.righthalf.filled")
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
            Label("Close Pane", systemImage: "xmark")
        }
    }

    /// Fire an Edit-menu selector through the responder chain, reaching the
    /// focused `GhosttySurfaceView` (mirrors the Edit-menu Copy/Paste in
    /// `CasperCommands` (MenuCommands.swift), which also dispatch through the
    /// responder chain).
    private func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
