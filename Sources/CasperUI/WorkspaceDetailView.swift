import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed on
    /// appear and on every diff revision (see `refreshDiffSummary`).
    @State private var diff: (insertions: Int, deletions: Int)?

    /// The in-flight summary refresh, if any. Cancelled and replaced on every new
    /// revision so rapid changes can't leave two tasks racing to settle `diff` on a
    /// stale value, and cancelled on disappear so none outlives this view.
    @State private var diffSummaryTask: Task<Void, Never>?

    /// Live inspector width, seeded per-workspace on appear (the detail view has
    /// a per-workspace `.id`, so this resets on every workspace switch) and
    /// persisted on drag-end. Held locally so the divider drag never mutates
    /// observed model state mid-layout.
    @State private var inspectorWidth: Double?

    /// Keep at least this much room for the detail area when clamping the
    /// inspector's maximum width.
    private static let minDetailWidth: Double = 320

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
                    LayoutNodeView(
                        model: model, workspaceID: workspace.id, node: workspace.layout,
                        canDragPanes: Self.hasMultiplePanes(in: workspace.layout))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The inspector region (divider + panel) is ALWAYS mounted and
                // pinned at its full width; collapsing animates the OUTER clip
                // width to zero instead of unmounting the panel with a `.move`
                // transition. Revealing by clipping keeps the panel at fixed
                // coordinates (content pinned to the trailing edge, which is the
                // window's fixed right edge) so nothing translates, mirroring
                // `SplitContainerView`'s always-mounted, frame-animated
                // approach. The divider lives inside the same clipped container
                // so it reveals with the panel rather than popping in as a
                // separate mount.
                HStack(spacing: 0) {
                    inspectorDivider(total: proxy.size.width, range: range)
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: width)
                }
                .frame(width: workspace.inspector.collapsed ? 0 : SeparatorMetrics.visibleWidth + width,
                       alignment: .trailing)
                .clipped()
            }
            .coordinateSpace(.named(Self.inspectorDragSpace))
            .animation(.easeInOut(duration: 0.18), value: workspace.inspector.collapsed)
        }
        .toolbar {
            // These three leading chips share ONE toolbar item: AppKit inserts its
            // own spacing between separate toolbar items, which left the
            // glyph-only info chip visually adrift from its neighbours. Each chip
            // keeps its own interior padding, so that padding — not the system's
            // inter-item gap — is what separates them now.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 0) {
                    title
                    WorkspaceInfoButton(model: model, workspace: workspace)
                    diffBadge
                }
            }
            .flatToolbarItem()
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
            // The two inspector tabs are mutually exclusive, so they share ONE item
            // and render as a single segmented control rather than as two independent
            // pills. Flattened like the Script and Editor chips: it draws its own
            // capsule, so the system shared glass is stripped in every state.
            ToolbarItem(placement: .primaryAction) {
                InspectorTabSelector(model: model, workspace: workspace)
            }
            .flatToolbarItem()
        }
        .alert("Couldn't Open Editor", isPresented: Binding(
            get: { model.editorLaunchError != nil },
            set: { if !$0 { model.editorLaunchError = nil } }
        )) {
            // Empty: dismissing the alert flips `isPresented` to false, and that
            // binding's setter is what clears the error.
            Button("OK", role: .cancel) {}
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
        .onAppear {
            // `RootView` gives this view a per-workspace `.id`, so one instance only
            // ever renders one workspace — the first summary needs no keying.
            refreshDiffSummary()
        }
        .onChange(of: model.diffRevision) { _, _ in
            refreshDiffSummary()
        }
        .onDisappear {
            // Switching workspaces tears this instance down and discards its `@State`;
            // without this the git diff behind the last refresh would keep running,
            // holding `model`, to produce a summary nothing can display any more.
            diffSummaryTask?.cancel()
        }
    }

    /// Recompute the diff summary, cancelling any refresh still in flight. Every
    /// refresh — the first one included — goes through this single task, so
    /// overlapping revisions can't race to settle `diff` on a stale value.
    private func refreshDiffSummary() {
        diffSummaryTask?.cancel()
        diffSummaryTask = Task { @MainActor in
            let summary = await model.diffService.diffSummary(for: workspace)
            guard !Task.isCancelled else { return }
            diff = summary
        }
    }

    /// Whether the workspace shows more than one pane. True exactly when its root
    /// layout is a split: `LayoutTree` never builds a split with fewer than two
    /// children (it collapses a split down to its survivor when one is closed), so
    /// this needs no tree walk.
    static func hasMultiplePanes(in layout: LayoutNode) -> Bool {
        if case .split = layout { return true }
        return false
    }

    /// Allowed inspector-width range for the given container width: never below
    /// `InspectorState.minWidth`, never above `InspectorState.maxWidth`, and
    /// always leaving at least `minDetailWidth` for the detail area.
    private func inspectorRange(container: Double) -> ClosedRange<Double> {
        let upper = max(InspectorState.minWidth,
                        min(InspectorState.maxWidth, container - Self.minDetailWidth))
        return InspectorState.minWidth...upper
    }

    /// A self-drawn vertical divider (mirrors `SplitContainerView`'s splitter): the
    /// shared `SeparatorMetrics` line for layout, with the equally shared transparent
    /// grab strip overlaid on top — straddling the line and carrying the
    /// column-resize pointer — so the hit area never reserves visible layout width.
    /// Dragging it resizes the inspector; the model is persisted only on drag-end.
    private func inspectorDivider(total: Double, range: ClosedRange<Double>) -> some View {
        Rectangle()
            .fill(SeparatorMetrics.fill)
            .frame(width: SeparatorMetrics.visibleWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: SeparatorMetrics.grabWidth)
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
        // Chrome-less on purpose: the title is not a control, so it keeps the
        // shared capsule metrics (alignment with the chips) without the pill.
        // Asymmetric interior padding (not the shared `titleCapsule`'s symmetric
        // 10 pt): the leading edge still owes its distance to the window edge,
        // while the trailing edge is tuned so the title-to-glyph gap (this
        // inset + the info button's own 2 pt inner padding) matches the
        // glyph-to-badge gap on the other side of the info chip.
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .titleCapsuleShell(filled: false)
    }

    @ViewBuilder private var diffBadge: some View {
        if let diff, diff.insertions > 0 || diff.deletions > 0 {
            Button {
                model.toggleInspectorTab(.diff, for: workspace.id)
            } label: {
                HStack(spacing: 5) {
                    Text("+\(diff.insertions)").foregroundStyle(DiffLineStyle.insertionTint.opacity(0.9))
                    Text("−\(diff.deletions)").foregroundStyle(DiffLineStyle.deletionTint.opacity(0.9))
                }
                .font(.body.monospacedDigit().bold())
                .titleCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .help("Toggle diff")
        }
    }

    private var editorButton: some View {
        let current = model.resolvedEditor(nil, for: workspace)
        return TitleSplitButton {
            model.openInEditor(nil, for: workspace.id)
        } primaryLabel: {
            if let current {
                editorLabel(current)
            } else {
                Text("Editor")
            }
        } menuContent: {
            ForEach(model.availableEditors, id: \.self) { kind in
                Button {
                    model.selectEditor(kind, for: workspace.id)
                } label: {
                    editorLabel(kind)
                }
            }
        }
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

/// The title-bar Diff / Browser control: one capsule enclosing both glyph-only
/// segments, with a single indicator that slides from one to the other. Rendering
/// them as one segmented control — rather than as two identical pills — is what
/// makes it legible that at most one tab can be on.
///
/// Three states are visible: the panel open on Diff, open on Browser, and
/// collapsed. Collapsed draws NO indicator at all, so "neither is on" reads as
/// distinct from either selection.
///
/// Each segment routes through `toggleInspectorTab`, which expands onto its tab
/// when the panel is collapsed, collapses the panel when it is already open on
/// that tab, and otherwise just switches tab.
///
/// Geometry follows the `title-capsule-hit-area` memory note: the shell wraps the
/// whole `HStack`, and the interior padding lives inside each `Button`'s label so
/// both halves of the pill are clickable rather than just the glyphs.
///
/// Internal rather than private so `InspectorTabSelectorTests` can host it.
struct InspectorTabSelector: View {
    /// Width of the slot each segment reserves for its glyph.
    ///
    /// Fixed on purpose: SF Symbols have different intrinsic widths (`plusminus`
    /// measures 12pt against `globe`'s 15pt), so content-sized segments would come
    /// out lopsided and the sliding selection indicator would change size as it
    /// moves between them. Reserving one slot makes both segments identical by
    /// construction. Deliberately roomier than the widest glyph — a slightly
    /// generous segment looks fine, an overflowing one does not.
    static let glyphSlotWidth: CGFloat = 18

    let model: AppModel
    let workspace: Workspace

    /// Anchors the one selection indicator so it slides horizontally between the
    /// segments instead of cross-fading.
    @Namespace private var selectionNamespace

    var body: some View {
        // `nil` while the panel is collapsed — the "neither is on" state.
        let selection: InspectorTab? = workspace.inspector.collapsed ? nil : workspace.inspector.tab
        return HStack(spacing: 0) {
            segment(.diff, systemImage: "plusminus", help: "Toggle diff", selection: selection)
            segment(.browser, systemImage: "globe", help: "Toggle browser", selection: selection)
        }
        .titleCapsuleShell(interactive: true)
        // One value covering both which tab is selected and whether the panel is
        // collapsed, so the indicator animates on either change.
        .animation(.smooth(duration: 0.22), value: selection)
    }

    /// One glyph-only segment. `help` names it for both the tooltip and VoiceOver.
    private func segment(_ tab: InspectorTab, systemImage: String, help: String,
                         selection: InspectorTab?) -> some View {
        let isSelected = selection == tab
        return Button {
            model.toggleInspectorTab(tab, for: workspace.id)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                // The fixed slot goes INSIDE the padding so the 10pt insets still
                // widen the segment (see the `fixed-frame-swallows-inner-padding`
                // memory note) and the whole pill half stays clickable.
                .frame(width: Self.glyphSlotWidth)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                // The indicator exists only behind the selected segment and is
                // matched across the two, so it slides rather than cross-fades.
                // Per-segment hover is deliberately absent: the shell already
                // lights up as a whole, as the Run / Editor pills do.
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color(nsColor: .controlColor))
                            .padding(3)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selectedTab", in: selectionNamespace, isSource: true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A title-bar split button: a primary `Button` and a borderless `Menu` sharing
/// one capsule shell, as used by the Run Script and Editor chips.
///
/// The geometry is the load-bearing part (see the `title-capsule-hit-area` memory
/// note). The capsule SHELL wraps the WHOLE `HStack` so it is one visible shape
/// enclosing both controls: a `Menu` renders its disclosure chevron OUTSIDE its
/// label view, so styling only the label never produces an enclosing pill. The
/// capsule's interior insets therefore live INSIDE each control's label rather than
/// on the shell — no child can reach into the shell's own padding — which is what
/// makes the whole pill clickable instead of just the glyph/text. The primary
/// button takes no `maxWidth`, so it stays content-sized and never stretches the
/// toolbar.
private struct TitleSplitButton<PrimaryLabel: View, MenuContent: View>: View {
    let action: () -> Void
    @ViewBuilder let primaryLabel: () -> PrimaryLabel
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                primaryLabel()
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu(content: menuContent) {
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
        .titleCapsuleShell(interactive: true)
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
        return TitleSplitButton {
            if let current { model.runScript(current.name, for: workspace.id) }
        } primaryLabel: {
            Label(current?.displayName ?? "Run", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
        } menuContent: {
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
        }
        .help("Run Script")
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.85)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }
}

/// The capsule chrome itself — fixed height, fill, hairline border, hit shape —
/// plus the hover highlight that makes an interactive chip read as clickable.
///
/// It lives in a `ViewModifier` (rather than as `.onHover` on each call site) for
/// the `@State` it needs, and because sitting on the shell makes hover cover the
/// WHOLE pill, including the nested borderless `Menu` chevron of the split
/// buttons — a per-control `.onHover` would flicker as the pointer crosses them.
private struct TitleCapsuleChrome: ViewModifier {
    let filled: Bool
    /// Buttons opt in; the branch/space `title` chip is not clickable, so it stays
    /// hover-inert and renders exactly as it did before hover existed.
    let interactive: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var highlighted: Bool { interactive && hovering }

    /// Native toolbar controls dim when the window stops being key/main, so the
    /// interactive chips dim with them. Fading the whole shell keeps the glyphs,
    /// the +N/−N tints and the capsule in step, and opacity alone can never shift
    /// the layout.
    private var shellOpacity: Double { controlActiveState == .inactive ? 0.5 : 1 }

    /// An unfilled chip grows the standard fill + border on hover, so the capsule
    /// "appears" like a native toolbar button. Padding, height and hit area are
    /// already identical in both states, so this can never shift the layout.
    private var showsChrome: Bool { filled || highlighted }

    private var fill: Color {
        guard showsChrome else { return .clear }
        // Same step in both palettes.
        return Color.secondary.opacity(highlighted ? 0.28 : 0.15)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shell = content
            .frame(height: 36)
            .background(fill, in: Capsule())
            .overlay(showsChrome ? Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) : nil)
            .contentShape(Capsule())

        if interactive {
            shell
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .opacity(shellOpacity)
                .animation(.easeOut(duration: 0.12), value: controlActiveState)
        } else {
            shell
        }
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
    /// same padding, height, and hit area. Used by the branch/space `title`, which
    /// reads as a label rather than a chip yet still lines up with the chips next
    /// to it.
    ///
    /// Pass `interactive: true` for chips that are buttons, so they light up on
    /// hover like a native toolbar button; see `TitleCapsuleChrome`.
    func titleCapsule(filled: Bool = true, interactive: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .titleCapsuleShell(filled: filled, interactive: interactive)
    }

    /// The capsule chrome WITHOUT the interior horizontal padding. Split out from
    /// `titleCapsule` so a split-button (Run / Editor) can wrap the whole HStack in
    /// the visible pill while its inner controls carry the padding themselves —
    /// keeping that padding inside their clickable label instead of as dead
    /// decoration around a `.plain` button (see the `title-capsule-hit-area`
    /// memory note). `interactive` behaves as in `titleCapsule`.
    func titleCapsuleShell(filled: Bool = true, interactive: Bool = false) -> some View {
        modifier(TitleCapsuleChrome(filled: filled, interactive: interactive))
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
