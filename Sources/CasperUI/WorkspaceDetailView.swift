import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed when
    /// the selected workspace changes (see the `.task` below).
    @State private var diff: (insertions: Int, deletions: Int)?

    /// Live inspector width, seeded per-workspace on appear (the detail view has
    /// a per-workspace `.id`, so this resets on every workspace switch) and
    /// persisted on drag-end. Held locally so the divider drag never mutates
    /// observed model state mid-layout.
    @State private var inspectorWidth: Double?

    /// Keep at least this much room for the detail area when clamping the
    /// inspector's maximum width.
    private static let minDetailWidth: Double = 320

    /// Width of the inspector's visible 1pt separator line. Named so the reveal
    /// container can size itself to divider + panel in one place. The transparent
    /// grab strip is a wider OVERLAY (`inspectorGrabWidth`) that straddles this
    /// line without consuming layout width, so no background-coloured band shows
    /// between the terminal and the panel.
    private static let inspectorDividerWidth: Double = 1

    /// Width of the transparent grab strip overlaid on the 1pt line, widening the
    /// drag target (mirrors `SplitContainerView`'s splitter hitbox).
    private static let inspectorGrabWidth: Double = 18

    /// Stable coordinate space for the inspector divider drag, anchored to the
    /// full-width detail container so the pointer's absolute location is read
    /// against a fixed origin (the divider itself moves as the panel resizes).
    private static let inspectorDragSpace = "inspectorDrag"

    var body: some View {
        GeometryReader { proxy in
            let range = inspectorRange(container: proxy.size.width)
            let width = (inspectorWidth ?? workspace.inspector.width)
                .clamped(to: range)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The inspector region (divider + panel) is ALWAYS mounted and
                // pinned at its full width; collapsing animates the OUTER clip
                // width to zero instead of unmounting the panel with a `.move`
                // transition. A freshly inserted AppKit-hosted view — the
                // segmented `Picker` (an NSSegmentedControl) — does not follow
                // SwiftUI's per-frame transition offset: it snaps to its final
                // frame and visibly lags the sliding chrome. Revealing by
                // clipping keeps that control at fixed coordinates (content
                // pinned to the trailing edge, which is the window's fixed right
                // edge) so nothing translates, mirroring `SplitContainerView`'s
                // always-mounted, frame-animated approach. The divider lives
                // inside the same clipped container so it reveals with the panel
                // rather than popping in as a separate mount.
                HStack(spacing: 0) {
                    inspectorDivider(total: proxy.size.width, range: range)
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: width)
                }
                .frame(width: workspace.inspector.collapsed ? 0 : Self.inspectorDividerWidth + width,
                       alignment: .trailing)
                .clipped()
            }
            .coordinateSpace(.named(Self.inspectorDragSpace))
            .animation(.easeInOut(duration: 0.18), value: workspace.inspector.collapsed)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { title }
            ToolbarItem(placement: .navigation) { diffBadge }.flatToolbarItem()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            if !model.namedCommands(for: workspace.id).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    scriptButton
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                .flatToolbarItem()
            }
            if !model.availableEditors.isEmpty {
                ToolbarItem(placement: .primaryAction) { editorButton }.flatToolbarItem()
            }
            // Expanded: strip the glass so the toggle doesn't merge into the diff
            // badge's capsule (a macOS 26 glass-merge artifact). Collapsed: keep it.
            let inspectorItem = ToolbarItem(placement: .primaryAction) { inspectorToggle }
            if workspace.inspector.collapsed {
                inspectorItem
            } else {
                inspectorItem.flatToolbarItem()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.namedCommands(for: workspace.id).isEmpty)
        .alert("Couldn't Open Editor", isPresented: Binding(
            get: { model.editorLaunchError != nil },
            set: { if !$0 { model.editorLaunchError = nil } }
        )) {
            Button("OK") { model.editorLaunchError = nil }
        } message: {
            Text(model.editorLaunchError ?? "")
        }
        .alert("Couldn't Run Script", isPresented: Binding(
            get: { model.scriptRunError != nil },
            set: { if !$0 { model.scriptRunError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.scriptRunError ?? "")
        }
        .task(id: model.selectedWorkspaceID) {
            diff = model.diffSummary(for: workspace)
        }
        .onChange(of: model.diffRevision) { _, _ in
            diff = model.diffSummary(for: workspace)
        }
        .onAppear {
            if inspectorWidth == nil { inspectorWidth = workspace.inspector.width }
        }
    }

    /// Allowed inspector-width range for the given container width: never below
    /// `InspectorState.minWidth`, never above `InspectorState.maxWidth`, and
    /// always leaving at least `minDetailWidth` for the detail area.
    private func inspectorRange(container: Double) -> ClosedRange<Double> {
        let upper = max(InspectorState.minWidth,
                        min(InspectorState.maxWidth, container - Self.minDetailWidth))
        return InspectorState.minWidth...upper
    }

    /// A self-drawn vertical divider (mirrors `SplitContainerView`'s splitter): a
    /// 1pt separator line for layout, with a wider transparent grab strip overlaid
    /// on top — straddling the line and carrying the column-resize pointer — so the
    /// hit area never reserves visible layout width. Dragging it resizes the
    /// inspector; the model is persisted only on drag-end.
    private func inspectorDivider(total: Double, range: ClosedRange<Double>) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Self.inspectorDividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: Self.inspectorGrabWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.inspectorDragSpace))
                            .onChanged { value in
                                // Track the pointer's ABSOLUTE x in the stable container space:
                                // the inspector's left edge sits at value.location.x, so its
                                // width is the space remaining to the right. Using the absolute
                                // location (not accumulated translation) keeps the divider
                                // locked to the pointer even as the panel — and this divider —
                                // shift during the drag, eliminating the resize lag.
                                inspectorWidth = (total - value.location.x).clamped(to: range)
                            }
                            .onEnded { _ in
                                if let width = inspectorWidth {
                                    model.setInspectorWidth(width, for: workspace.id)
                                }
                            })
            }
    }

    private var title: some View {
        HStack(spacing: 7) {
            // Mirror WorkspaceRow: git-branch glyph + branch label for a
            // Git-backed Space, folder glyph + Space name for a degenerate one.
            if isGitRepo {
                Octicon(.gitBranch).foregroundStyle(.secondary)
                Text(workspace.branchLabel)
                    .fontWeight(.bold)
                Text(spaceName).foregroundStyle(.secondary)
            } else {
                Octicon(.fileDirectory).foregroundStyle(.secondary)
                Text(spaceName)
                    .fontWeight(.bold)
            }
        }
        .padding(.horizontal, 10)
    }

    private var isGitRepo: Bool {
        model.isWorkspaceGitBacked(workspace)
    }

    private var spaceName: String {
        model.space(for: workspace)?.name ?? workspace.name
    }

    @ViewBuilder private var diffBadge: some View {
        if let diff, diff.insertions > 0 || diff.deletions > 0 {
            Button {
                model.setInspectorTab(.diff, for: workspace.id)
            } label: {
                let content = HStack(spacing: 5) {
                    Text("+\(diff.insertions)").foregroundStyle(DiffLineStyle.insertionTint.opacity(0.9))
                    Text("−\(diff.deletions)").foregroundStyle(DiffLineStyle.deletionTint.opacity(0.9))
                }
                .font(.body.monospacedDigit().bold())
                .padding(.horizontal, 8)
                // Match the branch capsule: same Liquid Glass material (.glassEffect) and
                // same height, but keep the badge a DISTINCT pill (its toolbar item is
                // flattened so it doesn't merge into the branch's shared glass). 36 pt is
                // the branch capsule's real height on a Retina display — off-screen window
                // captures under-report the system glass, so it was calibrated live.
                .frame(height: 36)
                if #available(macOS 26.0, *) {
                    content
                        .glassEffect(in: .capsule)
                        .contentShape(Capsule())
                } else {
                    content
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .help("Show diff")
        }
    }

    private var inspectorToggle: some View {
        Button {
            model.toggleInspectorCollapsed(for: workspace.id)
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help("Toggle panel")
    }

    private var scriptButton: some View {
        let commands = model.namedCommands(for: workspace.id)
        let current = model.resolvedScript(for: workspace)
        let content = HStack(spacing: 4) {
            Button {
                if let current { model.runScript(current.name, for: workspace.id) }
            } label: {
                Label(current?.name ?? "Run", systemImage: "play.fill")
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(commands, id: \.name) { command in
                    Button {
                        model.selectScript(command.name, for: workspace.id)
                    } label: {
                        if command.name == current?.name {
                            Label(command.name, systemImage: "checkmark")
                        } else {
                            Text(command.name)
                        }
                    }
                }
            } label: {
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        return content
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
            .help("Run Script")
    }

    private var editorButton: some View {
        let current = model.resolvedEditor(nil, for: workspace)
        let content = HStack(spacing: 4) {
            Button {
                model.openInEditor(nil, for: workspace.id)
            } label: {
                if let current {
                    editorLabel(current)
                } else {
                    Text("Editor")
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(model.availableEditors, id: \.self) { kind in
                    Button {
                        model.selectEditor(kind, for: workspace.id)
                    } label: {
                        editorLabel(kind)
                    }
                }
            } label: {
                // .menuStyle(.borderlessButton) always appends its own disclosure chevron
                // after the label, so a label chevron here would render twice (⌄⌄). Keep
                // the label empty and let the style's own arrow be the only visible one.
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        // Match the branch capsule / diff badge: same Liquid Glass material and same
        // height, drawn around the WHOLE HStack (primary button + chevron menu) so the
        // capsule is one visible shape enclosing both regions — Menu's own primaryAction
        // chrome renders its disclosure chevron OUTSIDE the label view, so styling only
        // the label (the previous attempt) never produces a visible enclosing pill.
        .frame(height: 36)
        return content
            // Unlike diffBadge, .glassEffect(in: .capsule) renders this pill nearly
            // invisible when the HStack contains a nested borderless-style Menu — the
            // native control mid-hierarchy interferes with the glass material's
            // compositing. Use an explicit, unconditional background instead so the
            // pill stays visible on every macOS version.
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
            .help("Open in Editor")
    }

    @ViewBuilder
    private func editorLabel(_ kind: EditorKind) -> some View {
        if let icon = EditorLauncher.icon(for: kind) {
            Label { Text(kind.displayName) } icon: { Image(nsImage: icon) }
        } else {
            Text(kind.displayName)
        }
    }

}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension ToolbarContent {
    /// Removes the automatic macOS 26 "Liquid Glass" capsule background that wraps
    /// toolbar item content, so the diff badge can draw its OWN distinct glass
    /// capsule instead of merging into the branch capsule's shared glass.
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
