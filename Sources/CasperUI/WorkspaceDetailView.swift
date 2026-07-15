import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed when
    /// the selected workspace changes (see the `.task` below).
    @State private var diff: (insertions: Int, deletions: Int)?

    /// The in-flight `diffRevision`-driven summary refresh, if any. Cancelled and
    /// replaced on every new revision so rapid changes can't leave two tasks racing
    /// to settle `diff` on a stale value.
    @State private var diffSummaryTask: Task<Void, Never>?

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
        // Observe the scripts revision so a live `.casper.json` change re-runs the
        // `.toolbar` content — re-evaluating the Run Script visibility gate, its
        // menu list, and the resolved default (see `AppModel.scriptsRevision`).
        let _ = model.scriptsRevision
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
            ToolbarItem(placement: .navigation) { title }.flatToolbarItem()
            ToolbarItem(placement: .navigation) { diffBadge }.flatToolbarItem()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            if !model.namedCommands(for: workspace.id).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ScriptToolbarButton(model: model, workspace: workspace)
                }
                .flatToolbarItem()
            }
            if !model.availableEditors.isEmpty {
                ToolbarItem(placement: .primaryAction) { editorButton }.flatToolbarItem()
            }
            // Always flattened: the toggle draws its own capsule, so the system shared
            // glass is stripped in both states to keep it visually identical.
            ToolbarItem(placement: .primaryAction) { inspectorToggle }.flatToolbarItem()
        }
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
            diff = await model.diffSummary(for: workspace)
        }
        .onChange(of: model.diffRevision) { _, _ in
            // Cancel the previous refresh before starting a new one so overlapping
            // revisions can't race to settle `diff` on a stale value.
            diffSummaryTask?.cancel()
            diffSummaryTask = Task { @MainActor in
                let summary = await model.diffSummary(for: workspace)
                guard !Task.isCancelled else { return }
                diff = summary
            }
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
        // Resolve the owning Space once — `model.space(for:)` scans every Space's
        // workspaces, so both the git-backed flag and the name derive from this
        // single lookup rather than scanning the model twice per body pass.
        let space = model.space(for: workspace)
        let isGitRepo = space?.isGitRepo ?? false
        let spaceName = space?.name ?? workspace.name
        return HStack(spacing: 7) {
            // Mirror WorkspaceRow: git-branch glyph + "Space / branch" for a
            // Git-backed Space, folder glyph + Space name for a degenerate one.
            if isGitRepo {
                Octicon(.gitBranch).foregroundStyle(.secondary)
                Text(spaceName).foregroundStyle(.secondary)
                Text("/").foregroundStyle(.secondary)
                Text(workspace.branchLabel)
                    .fontWeight(.bold)
            } else {
                Octicon(.fileDirectory).foregroundStyle(.secondary)
                Text(spaceName)
                    .fontWeight(.bold)
            }
        }
        .titleCapsule()
    }

    @ViewBuilder private var diffBadge: some View {
        if let diff, diff.insertions > 0 || diff.deletions > 0 {
            Button {
                model.setInspectorTab(.diff, for: workspace.id)
            } label: {
                HStack(spacing: 5) {
                    Text("+\(diff.insertions)").foregroundStyle(DiffLineStyle.insertionTint.opacity(0.9))
                    Text("−\(diff.deletions)").foregroundStyle(DiffLineStyle.deletionTint.opacity(0.9))
                }
                .font(.body.monospacedDigit().bold())
                .titleCapsule()
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
                .titleCapsule(filled: workspace.inspector.collapsed)
        }
        .buttonStyle(.plain)
        .help("Toggle panel")
    }

    private var editorButton: some View {
        let current = model.resolvedEditor(nil, for: workspace)
        let content = HStack(spacing: 0) {
            Button {
                model.openInEditor(nil, for: workspace.id)
            } label: {
                Group {
                    if let current {
                        editorLabel(current)
                    } else {
                        Text("Editor")
                    }
                }
                // Carry the capsule's interior geometry INSIDE the label so the whole
                // pill region (leading padding + full height) triggers the primary
                // action, not just the glyph/text (see the `title-capsule-hit-area`
                // memory note). No `maxWidth` — the button stays sized to its content.
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
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
            // Fill the capsule's right inset so its trailing edge isn't a dead zone.
            .padding(.trailing, 10)
        }
        // The capsule SHELL wraps the WHOLE HStack (primary button + chevron menu) so it
        // is one visible shape enclosing both: Menu's own primaryAction chrome renders
        // its disclosure chevron OUTSIDE the label view, so styling only the label never
        // produces a visible enclosing pill. Interior padding lives inside each control's
        // label (not on the shell) so the whole pill is clickable, not just the glyphs.
        return content
            .titleCapsuleShell()
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

/// The "Run Script" toolbar split-button. A separate view so it carries its own
/// `@State`: `WorkspaceDetailView` is recreated per workspace (`.id`), so this
/// mounts fresh on each switch and plays an entrance animation via `onAppear`.
private struct ScriptToolbarButton: View {
    let model: AppModel
    let workspace: Workspace
    @State private var appeared = false

    var body: some View {
        let commands = model.namedCommands(for: workspace.id)
        let current = model.resolvedScript(for: workspace)
        return HStack(spacing: 0) {
            Button {
                if let current { model.runScript(current.name, for: workspace.id) }
            } label: {
                Label(current?.displayName ?? "Run", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    // Carry the capsule's interior geometry INSIDE the label so the
                    // whole pill region (leading padding + full height) triggers the
                    // primary action, not just the glyph/text (see the
                    // `title-capsule-hit-area` memory note). No `maxWidth` — the
                    // button stays sized to its content so the toolbar doesn't stretch.
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(commands, id: \.name) { command in
                    Button {
                        model.selectScript(command.name, for: workspace.id)
                    } label: {
                        if command.name == current?.name {
                            Label(command.displayName, systemImage: "checkmark")
                        } else {
                            Text(command.displayName)
                        }
                    }
                }
            } label: {
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Fill the capsule's right inset so its trailing edge isn't a dead zone.
            .padding(.trailing, 10)
        }
        .titleCapsuleShell()
        .help("Run Script")
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.85)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }
}

private extension View {
    /// The one shared title-bar capsule chrome. Every title-bar chip uses this so
    /// they render strictly identically. Explicit fill + hairline border (not
    /// Liquid Glass) because glass renders nearly invisible on chips that embed a
    /// nested borderless `Menu` (Run / Editor), so this is the only treatment that
    /// works for every chip.
    ///
    /// Pass `filled: false` to drop the fill and border while keeping the exact
    /// same padding, height, and hit area — used by the inspector toggle so its
    /// background vanishes when the panel is open but the button never shifts.
    func titleCapsule(filled: Bool = true) -> some View {
        self
            .padding(.horizontal, 10)
            .titleCapsuleShell(filled: filled)
    }

    /// The capsule chrome WITHOUT the interior horizontal padding: fixed height,
    /// fill, hairline border, and hit shape. Split out from `titleCapsule` so a
    /// split-button (Run / Editor) can wrap the whole HStack in the visible pill
    /// while its inner controls carry the padding themselves — keeping that
    /// padding inside their clickable label instead of as dead decoration around
    /// a `.plain` button (see the `title-capsule-hit-area` memory note).
    func titleCapsuleShell(filled: Bool = true) -> some View {
        self
            .frame(height: 36)
            .background(filled ? Color.secondary.opacity(0.15) : .clear, in: Capsule())
            .overlay(filled ? Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) : nil)
            .contentShape(Capsule())
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
