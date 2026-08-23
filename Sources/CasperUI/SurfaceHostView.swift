import AppKit
import CasperCore
import CasperGhostty
import SwiftUI

/// Renders a single `Surface` (a tmux-style pane) and attaches the pane
/// context menu: four splits (each creating a new terminal), copy/paste, and
/// close. Surface identity anchors on `Surface.id`, so the persistent view
/// cache in `AppModel` keeps each PTY / web page alive across layout churn.
struct SurfaceHostView: View {
    let model: AppModel
    let workspaceID: UUID
    let surface: Surface
    /// Whether this pane can be dragged (and is a drop target): true only when the
    /// workspace has more than one pane, as a lone pane has nowhere to move.
    /// Resolved once per workspace by `WorkspaceDetailView` and threaded down, so
    /// no pane walks the layout tree on its own body pass.
    let canDrag: Bool

    /// Measured pane size, feeding the drop delegate's zone computation.
    @State private var paneSize: CGSize = .zero

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

    /// A short label for the drag preview: the terminal's directory name.
    private var dragLabel: String {
        guard case .terminal(let cwd) = surface.kind else { return "Terminal" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Terminal" : name
    }

    @ViewBuilder
    private var content: some View {
        if let view = model.surfaceView(for: surface, in: workspaceID) {
            PersistentNSViewHost(view: view).id(surface.id)
        } else {
            // Two ways to land here. Before launch finishes, the runtime is not ready
            // and no view can exist yet. Far more often, this is the departing pane's
            // final body pass after `applyCloseSurface` removed `surface` from the
            // layout: `surfaceView(for:in:)` refuses to build a view for a surface the
            // layout no longer holds, and this frame is the last one drawn.
            Color.black
        }
    }

    /// The pane context menu, rendered from the shared
    /// `PaneMenuItem.groups(model:surfaceID:)` description so it stays identical to
    /// the AppKit twin in `PaneContextMenu.swift`.
    private var paneMenu: some View {
        MenuGroups(groups: PaneMenuItem.groups(model: model, surfaceID: surface.id), itemID: \.title) { item in
            Button(role: item.isDestructive ? .destructive : nil, action: item.action) {
                Label(item.title, systemImage: item.systemImage)
            }
            .keyboardShortcut(item.commandKey.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        }
    }
}
