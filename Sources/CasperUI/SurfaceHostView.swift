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
        // Hoisted: `canDrag` walks the whole layout tree and builds two arrays, and
        // every pane's body reads it three times.
        let canDrag = canDrag
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
        if let view = model.surfaceView(for: surface, in: workspace) {
            PersistentNSViewHost(view: view).id(surface.id)
        } else {
            Color.black  // runtime not ready yet
        }
    }

    /// The pane context menu, rendered from the shared
    /// `PaneMenuItem.groups(model:surfaceID:)` description so it stays identical to
    /// the AppKit twin in `PaneContextMenu.swift`.
    @ViewBuilder
    private var paneMenu: some View {
        let groups = PaneMenuItem.groups(model: model, surfaceID: surface.id)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.title) { item in
                Button(role: item.isDestructive ? .destructive : nil, action: item.action) {
                    Label(item.title, systemImage: item.systemImage)
                }
                .keyboardShortcut(item.commandKey.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
            }
        }
    }
}
