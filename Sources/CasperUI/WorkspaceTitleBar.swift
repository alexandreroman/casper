import AppKit
import CasperCore
import SwiftUI

/// The whole title bar, laid out in one row of a known width.
///
/// It is one view because it is one `ToolbarItem` (see the `.toolbar` comment in
/// `WorkspaceDetailView`). As that width shrinks, the row degrades along ONE ordered
/// ladder — the diff badge first, then the Space name, then the chip labels, and
/// never the branch — spelled out in `body` and in app-ui.md § Title bar.
struct WorkspaceTitleBarRow: View {
    let model: AppModel
    let workspace: Workspace
    /// The diff badge's counts, from `DiffService.diffSummary`; nil hides the badge.
    let diff: (insertions: Int, deletions: Int)?
    let width: CGFloat

    /// Report what the badge and the chips laid out to, so the row's layout tests can
    /// see which rung it settled on. A fixed-width stack tells an outside observer
    /// nothing about what is inside it, and the ladder's order — and its
    /// monotonicity — is precisely what needs pinning. Unused by the app.
    var onBadgeWidth: ((CGFloat) -> Void)?
    var onChipsWidth: ((CGFloat) -> Void)?

    #if DEBUG
    /// Report which rung of the ladder below actually laid out — the one thing the two
    /// widths above cannot say, since a density's width depends on which chips the
    /// workspace even offers and the title's form is not a function of width at all.
    /// Set only while a resize trace is armed (see `TitleBarResizeTrace`), and nil
    /// otherwise, which is what keeps the reporter — and the `TitleBarRung` it would
    /// name — out of the view tree.
    var onRung: ((TitleBarRung) -> Void)?
    #endif

    var body: some View {
        // Resolved once per body pass rather than per title: `model.space(for:)` scans
        // every Space's workspaces, and `ViewThatFits` builds all six rungs below.
        let space = model.space(for: workspace)
        // ONE ordered list for everything that yields, widest first, each rung giving
        // up exactly one thing: the badge (informational), then the Space name
        // (context), then the chip labels (actions). The branch (identity) never goes.
        // One list rather than one ladder per element, because two ladders cannot be
        // ordered against each other: whatever one releases, the other takes back
        // (measured, and tabulated rung by rung, in app-ui.md § Title bar). Within a
        // rung the branch still middle-truncates — `Text` answering a proposal, which
        // changes how a rung looks, never which rung is chosen.
        ViewThatFits(in: .horizontal) {
            rung(title: .spaceAndBranch, badge: true, chips: .full, space: space)
            rung(title: .spaceAndBranch, badge: false, chips: .full, space: space)
            rung(title: .branchOnly, badge: false, chips: .full, space: space)
            rung(title: .branchOnly, badge: false, chips: .mergeGlyph, space: space)
            rung(title: .branchOnly, badge: false, chips: .folded, space: space)
            rung(title: .branchOnly, badge: false, chips: .minimal, space: space)
        }
        // Giving the row a definite width is what drives the ladder: it hands it a real
        // proposal, which a toolbar item on its own never does.
        .frame(width: width, alignment: .leading)
        // Spanning the bar takes `NSThemeFrame`'s window drag and title-bar double-click
        // away, so a clear layer BEHIND the row carries both: a sibling of the chips,
        // never a gesture on their ancestor, which would delay every chip's press. See
        // the `titlebar-row-window-drag` note for the layer's shape and placement.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { performTitleBarDoubleClickAction() }
                .gesture(WindowDragGesture())
        }
    }

    /// Run the title bar's configured double-click action on the key window.
    ///
    /// The key window is this row's window: Casper has no New Window command
    /// (`CasperCommands` replaces `.newItem` with Space), and both auxiliary
    /// `NSWindow`s are borderless and never ordered on-screen. A sheet is the one
    /// other thing that takes key, which the guard below turns away.
    private func performTitleBarDoubleClickAction() {
        guard let window = NSApp.keyWindow else { return }
        // `performZoom` and `performMiniaturize` BEEP at a window that cannot honour
        // them, where the theme frame is silent. Two windows here cannot: one showing
        // or belonging to a sheet (the close-progress sheet in `RootView` makes the
        // sheet key), and a full-screen one.
        guard window.sheetParent == nil, window.attachedSheet == nil,
            !window.styleMask.contains(.fullScreen)
        else { return }

        let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch TitleBarDoubleClickAction.action(for: setting) {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .fill:
            // Fill has no `NSWindow` verb of its own: it is the window taking the
            // screen's whole visible frame, which zoom does not guarantee.
            if let screen = window.screen {
                window.setFrame(screen.visibleFrame, display: true)
            }
        case .none:
            break
        }
    }

    /// One rung, laid out left to right: title, badge, then the chips at the trailing
    /// edge. `space` is the workspace's owning Space, which names the title.
    private func rung(
        title titleForm: WorkspaceTitleLabel.Form, badge: Bool,
        chips: WorkspaceToolbarActions.Density, space: Space?
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                title(titleForm, space: space)
                WorkspaceInfoButton(model: model, workspace: workspace)
            }
            // A group proposed less than its ideal width must truncate, never wrap:
            // without this the title pushes the title bar open instead of shortening
            // (see `WorkspaceTitleLabel` and the `toolbar-group-truncation` note).
            .lineLimit(1)
            // Served first, so the branch keeps its room and the chips are what give
            // way inside a rung.
            .layoutPriority(2)

            Group {
                if badge {
                    diffBadge
                }
            }
            // Both the badge and the chips are fixed at their ideal width inside a
            // rung, so a rung is all-or-nothing. Left flexible they compress instead:
            // `ViewThatFits` accepts a candidate that can squeeze its text, so the
            // chip labels would tighten a few points at a time and then spring back
            // to full width at the next rung — measured growing 253 -> 265 pt as the
            // row NARROWED past 601 pt. The title is the one thing that stays
            // flexible, because truncating the branch is what a rung is allowed to
            // do internally.
            .fixedSize(horizontal: true, vertical: false)
            // Fires with 0 on the rungs that drop the badge, which is what lets the
            // row's tests see that it went whole rather than shrank.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onBadgeWidth?($0) }

            Spacer(minLength: WorkspaceDetailView.chipGap)

            WorkspaceToolbarActions(model: model, workspace: workspace, density: chips)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    onChipsWidth?($0)
                }
        }
        #if DEBUG
        // Reported from INSIDE the rung, because that is what makes the report
        // trustworthy: `ViewThatFits` places only the candidate it chose, so only the
        // chosen rung's background is ever laid out. A background is proposed the
        // primary view's size and answers with it, so this cannot change the width
        // `ViewThatFits` measured — the row has to observe itself without disturbing
        // what it observes.
        //
        // The `if` is OUTSIDE the reporter, not a check inside it: a `background`
        // closure is evaluated while the body is being built, so a reporter built
        // unconditionally would construct one `TitleBarRung` per candidate — six per
        // body pass — in every DEBUG session, armed or not. This way an unarmed session
        // builds nothing here at all.
        .background {
            if let onRung {
                TitleBarRungReporter(
                    rung: TitleBarRung(title: titleForm, badge: badge, chips: chips),
                    report: onRung)
            }
        }
        #endif
    }

    private func title(_ form: WorkspaceTitleLabel.Form, space: Space?) -> some View {
        WorkspaceTitleLabel(
            isGitRepo: space?.isGitRepo ?? false,
            spaceName: space?.name ?? workspace.name,
            branchLabel: workspace.branchLabel,
            form: form)
        // Chrome-less on purpose: the title is not a control, so it keeps the
        // shared capsule metrics (alignment with the chips) without the pill.
        // Asymmetric interior padding (not the shared `titleCapsule`'s symmetric
        // inset): the leading edge still owes its distance to the window edge,
        // while the trailing edge is tuned so the title-to-glyph gap (this
        // inset + the info button's own 2 pt inner padding) matches the
        // glyph-to-badge gap on the other side of the info chip.
        .padding(.leading, TitleCapsuleMetrics.horizontalInset)
        .padding(.trailing, 6)
        .frame(height: TitleCapsuleMetrics.height)
        // Out of hit testing, so a click on the title falls through to the drag and
        // double-click layer behind the row (see `body`). Its text takes the clicks
        // that land on it, and the layer is the title's sibling, not its ancestor, so
        // a click the title takes never reaches it. Opting out is simpler
        // than repeating the gestures here: the title is not a control and answers no
        // pointer of its own, and one gesture site is one that cannot drift.
        .allowsHitTesting(false)
    }

    @ViewBuilder private var diffBadge: some View {
        // Any summary shows, `+0 −0` included; `DiffService.diffSummary` is what
        // leaves a worktree with nothing to show at nil.
        if let summary = diff {
            Button {
                model.toggleInspectorTab(.diff, for: workspace.id)
            } label: {
                diffCounters(summary)
                    .titleCapsule()
            }
            .buttonStyle(TitleChipButtonStyle())
            .help("Toggle diff")
        }
    }

    /// The badge's two counters.
    private func diffCounters(_ summary: (insertions: Int, deletions: Int)) -> some View {
        HStack(spacing: 5) {
            Text("+\(summary.insertions)").foregroundStyle(Color(nsColor: DiffLineStyle.insertionTint).opacity(0.9))
            Text("−\(summary.deletions)").foregroundStyle(Color(nsColor: DiffLineStyle.deletionTint).opacity(0.9))
        }
        .font(.body.monospacedDigit().bold())
    }
}


/// What double-clicking the title bar does, as System Settings > Desktop & Dock >
/// "Double-click a window's title bar to" offers it: Fill, Zoom, Minimize or Do
/// Nothing. The choice is stored under `AppleActionOnDoubleClick`, where Zoom is
/// written as `Maximize` and an untouched setting writes no key at all.
///
/// Split out from `WorkspaceTitleBarRow` so the mapping can be tested. Reading the
/// domain and calling the `NSWindow` verbs both need a real window and a real user,
/// so they stay at the call site where nothing could test them anyway; what is worth
/// pinning is this decision, which has an unset default and an unknown-value case to
/// get wrong, and both must land on zoom.
enum TitleBarDoubleClickAction {
    case zoom
    case minimize
    case fill
    case none

    /// The stored value read as an action. Anything unrecognised — a value from a
    /// later macOS, or no value at all — is zoom, which is what macOS itself does.
    static func action(for value: String?) -> Self {
        switch value {
        case "Minimize": .minimize
        case "Fill": .fill
        case "None": .none
        default: .zoom
        }
    }
}

/// Every trailing title-bar chip, in one row that gives way as the window narrows:
/// Merge, Run Script, Editor and the Diff / Browser selector.
///
/// - `.full` — every chip with its text:
///   `( ⤭ Merge )( ▶ Run )( icon VS Code ⌄)( ± | 🌐 )`.
/// - `.mergeGlyph` — Merge keeps a chip of its own, as a glyph; Run and Editor move
///   into the `⋯` menu: `( ⤭ )( ⋯ )( ± | 🌐 )`. Merge is the one action worth a chip
///   at this width, and Run and Editor have no glyph-only form on the bar at all —
///   they go from their full text form straight into the menu, because an icon alone
///   names neither "which script" nor "which editor" the way their labels do.
/// - `.folded` — Merge joins them: `( ⋯ )( ± | 🌐 )`.
/// - `.minimal` — the `⋯` chip alone, the selector's two toggles moving into its
///   menu. The floor, so the ladder still terminates in something that fits at the
///   narrowest window AppKit allows.
///
/// The point of the ladder is that AppKit's own toolbar overflow is never reached:
/// the custom SwiftUI chips render without their capsule chrome inside that
/// popover, and the segmented control clips to a lone glyph. Overflow is also why
/// the selector lives here rather than in a `ToolbarItem` of its own — AppKit can
/// only overflow an item it can single out.
///
/// Internal rather than private so `WorkspaceToolbarActionsTests` can host it and
/// measure each tier — same reason as `InspectorTabSelector`.
struct WorkspaceToolbarActions: View {
    /// The four tiers, widest first. Named for the row each one draws.
    enum Density: CaseIterable {
        /// Every chip with its text.
        case full
        /// Merge as a glyph chip beside the `⋯` menu that holds Run and Editor.
        case mergeGlyph
        /// One `⋯` chip and the selector.
        case folded
        /// The `⋯` chip alone.
        case minimal
    }

    let model: AppModel
    let workspace: Workspace
    /// Which tier to draw. Chosen by `WorkspaceTitleBarRow`, never here: the choice
    /// has to be made together with the diff badge's, or the two ladders disagree.
    let density: Density

    var body: some View {
        // Observe the scripts revision: the Run Script visibility gate, its menu
        // list and the resolved default are all read in this body, and the cache
        // behind `namedCommands(for:)` is `@ObservationIgnored`, so a live
        // `.casper.json` change reaches them only through the revision. Read here
        // rather than in `WorkspaceDetailView` so a script change re-renders this
        // row alone — the same scoping `MergeToolbarButton` uses for `optionKeyHeld`.
        let _ = model.scriptsRevision
        // Every chip label stays on ONE line. The row hands the chips a definite
        // width, and a `Text` given less than it wants answers by WRAPPING — mid-word
        // — which would push the title bar open instead of shortening (the failure
        // the `toolbar-group-truncation` note describes). A chip is a fixed-height
        // capsule, so a second line has nowhere to go.
        return row(density).lineLimit(1)
    }

    /// One tier, drawn. Non-private so the tests can measure each tier directly
    /// rather than inferring which one the row picked.
    @ViewBuilder
    func row(_ density: Density) -> some View {
        HStack(spacing: WorkspaceDetailView.chipGap) {
            switch density {
            case .full:
                if canMerge {
                    MergeToolbarButton(model: model, workspace: workspace, density: density)
                }
                if hasScripts {
                    ScriptToolbarButton(model: model, workspace: workspace)
                }
                if hasEditors {
                    editorChip
                }
            case .mergeGlyph:
                if canMerge {
                    MergeToolbarButton(model: model, workspace: workspace, density: density)
                }
                foldedChip(density)
            case .folded, .minimal:
                // Always drawn, whatever the action gates say: at these tiers the chip
                // is the only route to the actions it holds.
                foldedChip(density)
            }
            if Self.showsInspectorSelector(at: density) {
                InspectorTabSelector(model: model, workspace: workspace)
            }
        }
    }

    /// Whether the Diff / Browser control rides on the bar at `density`.
    ///
    /// The single source for that fact: the `⋯` menu's `Sidebar` entry is exactly its
    /// complement, so the control is reachable at every tier and duplicated at none.
    /// Read by the row and by the menu, which is what keeps the two from drifting —
    /// a menu listing what is already on the bar is the one thing the `⋯` chip must
    /// never do.
    static func showsInspectorSelector(at density: Density) -> Bool { density != .minimal }

    /// `Workspace.canMerge` for the workspace this row renders. Mirrors the menus'
    /// `canCloseSelectedWorkspace` gate, but derives from that workspace instead of
    /// the model's selection — the toolbar always acts on the workspace it is drawn
    /// for, which this view already holds.
    private var canMerge: Bool { workspace.canMerge }

    private var hasScripts: Bool { !model.namedCommands(for: workspace.id).isEmpty }

    private var hasEditors: Bool { !model.availableEditors.isEmpty }

    /// Text form only, for the same reason as the Run chip: an app icon alone does
    /// not say which editor will open, and the tier below lists them all by name in
    /// the `⋯` menu.
    private var editorChip: some View {
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
        .accessibilityLabel("Open in Editor")
    }

    @ViewBuilder
    private func editorLabel(_ kind: EditorKind) -> some View {
        if let icon = EditorLauncher.icon(for: kind) {
            Label { Text(kind.displayName) } icon: { AppIcon(image: icon) }
        } else {
            Text(kind.displayName)
        }
    }

    /// The `⋯` chip: every action the row can no longer show, behind one menu. At
    /// `.minimal` it also carries the Diff / Browser toggles, which have no
    /// segmented control left to live in.
    ///
    /// `.menuStyle(.button)` + `TitleChipButtonStyle` rather than the split
    /// buttons' `.borderlessButton`, so the capsule can live INSIDE the label and
    /// the whole pill stays clickable (see the `title-capsule-hit-area` note). A
    /// borderless menu ignores its label's height and keeps its click target on
    /// the bare glyph, which measured 20×14 against this chip's 38×36. The button
    /// menu style draws its label through the button style in the environment, so
    /// this chip also gets the same pressed look as its neighbours. The chrome
    /// stays the explicit fill + hairline border — never glass, which renders
    /// nearly invisible around a nested `Menu`
    /// (`glasseffect-nested-menu-invisible`).
    private func foldedChip(_ density: Density) -> some View {
        Menu {
            foldedMenuContent(density)
        } label: {
            Image(systemName: "ellipsis")
                .glyphSlot()
                .titleCapsule()
        }
        .menuStyle(.button)
        .buttonStyle(TitleChipButtonStyle())
        // The chip button style draws no disclosure chevron of its own; this
        // keeps it that way if the menu style is ever revisited — a `⋯` chip must
        // not carry an indicator.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    /// The `⋯` menu lists exactly what the bar cannot show, in the SAME order the
    /// chips appear in — Merge, Run Script, Editor, then the inspector — so the
    /// folded form reads like the row it stands in for. The two orders are coupled:
    /// changing one means changing the other.
    ///
    /// Its contents therefore vary by tier, and never duplicate a chip that is still
    /// on the bar: at `.mergeGlyph` the Merge chip is right beside it, so the menu
    /// opens on Run Script, and `Sidebar` appears only once the segmented control has
    /// folded in here too.
    @ViewBuilder
    private func foldedMenuContent(_ density: Density) -> some View {
        // Merge has its own chip at `.mergeGlyph`; below that it lives here.
        if canMerge, density != .mergeGlyph {
            // The chip's Option-held Merge → Delete swap is not reproduced here:
            // a menu has room for both at once, so there is nothing to disambiguate
            // with a modifier.
            Button("Merge and Close Workspace…") {
                model.presentCloseWorkspaceConfirmation(id: workspace.id)
            }
            Button("Delete Workspace…") {
                model.presentDeleteWorkspaceConfirmation(id: workspace.id)
            }
            // The destructive pair is the only group set apart; the three submenus
            // below read as one list.
            Divider()
        }
        if hasScripts {
            Menu("Run Script") {
                // These items RUN the script, unlike the split button's menu, which
                // only selects the one its primary action will run: a menu has no
                // primary action, so selecting without running would do nothing.
                ForEach(model.namedCommands(for: workspace.id), id: \.name) { command in
                    Button(command.displayName) {
                        model.runScript(command.name, for: workspace.id)
                    }
                    .disabled(model.isSetupRunning(in: workspace.id))
                }
            }
        }
        if hasEditors {
            Menu("Open in Editor") {
                ForEach(model.availableEditors, id: \.self) { kind in
                    Button {
                        model.openInEditor(kind, for: workspace.id)
                    } label: {
                        editorLabel(kind)
                    }
                }
            }
        }
        // Named for the panel it drives — the inspector panel on the right, not the
        // workspace column on the left that the toolbar's own sidebar toggle opens.
        if !Self.showsInspectorSelector(at: density) {
            Menu("Sidebar") {
                inspectorTabItems
            }
        }
    }

    /// The Diff / Browser toggles as menu items, for the tier that has no room left
    /// for the segmented control. They route through the very same mutator the
    /// segments use, so the three states the control makes visible survive the
    /// fold: a checkmark marks the tab currently showing, and neither is marked
    /// while the panel is collapsed.
    @ViewBuilder
    private var inspectorTabItems: some View {
        let showing: InspectorTab? = workspace.inspector.collapsed ? nil : workspace.inspector.tab
        inspectorTabItem(.diff, title: "Toggle Diff", showing: showing)
        inspectorTabItem(.browser, title: "Toggle Browser", showing: showing)
    }

    @ViewBuilder
    private func inspectorTabItem(_ tab: InspectorTab, title: String,
                                  showing: InspectorTab?) -> some View {
        Button {
            model.toggleInspectorTab(tab, for: workspace.id)
        } label: {
            if showing == tab {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
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
    /// The width this control always lays out to — two identical segments, and the
    /// capsule shell adds nothing around them.
    ///
    /// Each segment is one glyph chip wide, from the shared metrics: the sliding
    /// indicator would otherwise change size as it moved between two symbols of
    /// different widths, and the segments would not match the chips beside them.
    ///
    /// Exposed so the row's layout tests can assert against the control they
    /// describe: it rides in every tier but the last, so its width is part of what
    /// each of those tiers costs. `InspectorTabSelectorTests` pins it against the
    /// hosted control so the two cannot drift apart.
    static let intrinsicWidth: CGFloat = 2 * TitleCapsuleMetrics.glyphChipWidth

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
        .titleCapsuleShell()
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
                // The fixed slot goes INSIDE the padding so the insets still widen
                // the segment (see the `fixed-frame-swallows-inner-padding` memory
                // note) and the whole pill half stays clickable.
                .glyphSlot()
                .padding(.horizontal, TitleCapsuleMetrics.horizontalInset)
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
        .buttonStyle(TitleChipButtonStyle())
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
    /// Disables the primary action only; the menu stays open to choose from.
    var isActionEnabled = true
    let action: () -> Void
    @ViewBuilder let primaryLabel: () -> PrimaryLabel
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                primaryLabel()
                    .padding(.leading, TitleCapsuleMetrics.horizontalInset)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TitleChipButtonStyle())
            .disabled(!isActionEnabled)

            Menu(content: menuContent) {
                // .menuStyle(.borderlessButton) always appends its own disclosure chevron
                // after the label, so a label chevron here would render twice (⌄⌄). Keep
                // the label empty and let the style's own arrow be the only visible one.
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Fill the capsule's right inset so its trailing edge isn't a dead zone.
            .padding(.trailing, TitleCapsuleMetrics.horizontalInset)
        }
        .titleCapsuleShell()
    }
}

/// The "Run Script" toolbar split-button. It holds no state of its own; it stays a
/// separate view to keep the toolbar item's body readable.
private struct ScriptToolbarButton: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let commands = model.namedCommands(for: workspace.id)
        let current = model.resolvedScript(for: workspace)
        // Running waits for the workspace's setup hook; choosing the script does not, so
        // only the primary action is disabled meanwhile.
        return TitleSplitButton(isActionEnabled: !model.isSetupRunning(in: workspace.id)) {
            if let current { model.runScript(current.name, for: workspace.id) }
        } primaryLabel: {
            // Pinned explicitly: the toolbar environment resolves a `Label` icon-only
            // on its own and would drop the title (see the `toolbar-label-style`
            // note) — and the title is the whole point of this chip. Which script it
            // will run is exactly what the glyph cannot say, so there is no
            // glyph-only form of it on the bar: the tier below moves it into the `⋯`
            // menu, where every command is listed by name.
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
        .accessibilityLabel("Run Script")
    }
}

/// Internal rather than private so the row's tests can host it: the Merge/Delete
/// swap has to be pinned at equal width, and that is invisible from outside the row.
struct MergeToolbarButton: View {
    let model: AppModel
    let workspace: Workspace
    let density: WorkspaceToolbarActions.Density

    var body: some View {
        // Read here rather than in `WorkspaceDetailView`: the observation dependency
        // that re-renders the chip on every Option press and release is registered by
        // reading the property inside the body that draws it.
        let deleting = model.optionKeyHeld
        let help = deleting ? "Delete workspace" : "Merge and close workspace"
        return Button {
            if deleting {
                model.presentDeleteWorkspaceConfirmation(id: workspace.id)
            } else {
                model.presentCloseWorkspaceConfirmation(id: workspace.id)
            }
        } label: {
            let label = Label(deleting ? "Delete" : "Merge",
                              systemImage: deleting ? "trash" : "arrow.triangle.merge")
            Group {
                // Both styles are pinned explicitly: the toolbar environment's own
                // default is icon-only, so leaving it to that would drop the title at
                // `.full`, and it is not what the glyph tier should lean on either.
                if density == .full {
                    label.labelStyle(.titleAndIcon)
                } else {
                    // The shared slot is what keeps Merge and Delete the same size:
                    // `trash` is 3 pt wider than `arrow.triangle.merge`, so without it
                    // the chip would resize the instant Option is held — under a
                    // stationary pointer, which is exactly when a size change reads as
                    // a different control appearing.
                    label.labelStyle(.iconOnly).glyphSlot()
                }
            }
            // The capsule geometry stays INSIDE the label in both forms, so the whole
            // pill keeps firing the action rather than just the glyph.
            .titleCapsule()
        }
        .buttonStyle(TitleChipButtonStyle())
        .help(help)
        // In the glyph form the tooltip is the only thing naming the action, and it
        // names the action the click will actually perform.
        .accessibilityLabel(help)
    }
}

/// An application icon that redraws when the appearance switches.
///
/// The light/dark variant of an app icon comes from the system icon style and is
/// resolved when the image is drawn. SwiftUI rasterizes `Image(nsImage:)` once and
/// never redraws it for a system switch, so the icon would keep its first variant.
/// Keying the view on `colorScheme` (which flips at the same moment, as Casper
/// follows the system appearance) forces a fresh render.
private struct AppIcon: View {
    let image: NSImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: image)
            .id(colorScheme)
    }
}
