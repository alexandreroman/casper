import CasperCore
import SwiftUI

/// The toolbar's info button: present only while the workspace has a message,
/// pulsing until that message has been shown. Hovering reveals the panel after
/// a short 150ms dwell — brief enough that the reveal still feels immediate to
/// a deliberate hover, while requiring the pointer to sit still on the button
/// for a moment rather than reveal on the instant it arrives — and dismissal
/// waits out a grace period so the pointer can travel into
/// the popover to scroll it, select text, or click a link. Leaving the popover
/// re-arms that same grace-period dismissal, so the panel does not linger open
/// once the pointer moves away for good — the grace period is a bounded travel
/// allowance, not a one-way switch that disables hover dismissal for the rest
/// of the popover's life. A click opens it too, so the panel stays reachable
/// without hovering.
///
/// A separate view (rather than a `WorkspaceDetailView` computed property) so it
/// owns the hover and presentation `@State` without re-rendering the whole
/// detail view on every pointer move.
struct WorkspaceInfoButton: View {
    let model: AppModel
    let workspace: Workspace

    private static let hoverDelay: Duration = .milliseconds(150)
    private static let dismissGrace: Duration = .milliseconds(250)
    /// Width of the glyph's slot while visible. Measured, not guessed: an
    /// `NSHostingView` around just the label (icon + its `.frame(height: 36)` +
    /// `.padding(.horizontal, 2)`, at the toolbar's inherited font) reports a
    /// fitting width of 19pt; rounded up to 20 so the widest glyph
    /// (`info.circle.fill`) never clips.
    static let iconSlotWidth: CGFloat = 20
    /// Width the chip keeps even with no message, instead of collapsing all
    /// the way to 0. `.frame(width:)` fixes the size this view REPORTS to its
    /// parent HStack — the trailing padding below lives inside that frame, so
    /// once the frame itself goes to 0 the padding has no reported width left
    /// to contribute (confirmed empirically: an `NSHostingView` fitting-size
    /// probe reports exactly the frame's width, never more, no matter what
    /// padding sits inside it). Without a nonzero floor here, the branch
    /// title's own 4pt trailing inset (set in `WorkspaceDetailView`) would be
    /// the only thing separating the title from the diff badge — reads as
    /// cramped.
    static let collapsedWidth: CGFloat = 6

    @State private var isPresented = false
    /// The pending reveal or dismissal, cancelled whenever the pointer changes
    /// its mind — so a quick pass over the button leaves no scheduled work.
    @State private var pendingHover: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Mounted unconditionally — an `if let` gate here would make the
        // appear/disappear an INSERTION/REMOVAL, and this view lives inside an
        // AppKit-hosted `ToolbarItem`, where SwiftUI transitions never play
        // (unlike an in-window `if`/`Group`). Driving `opacity`/`scaleEffect`/
        // `frame(width:)` off `visible` below instead is a plain PROPERTY
        // animation, which AppKit-hosted toolbar content animates fine — see
        // `ScriptToolbarButton` in `WorkspaceDetailView.swift` for the same
        // convention on its own entrance. Do not "simplify" this back into a
        // `.transition` + `if let`; that is the bug this file was fixing.
        let visible = workspace.infoMarkdown != nil
        Button {
            reveal()
        } label: {
            Image(systemName: workspace.infoUnread ? "info.circle.fill" : "info.circle")
                .symbolEffect(.pulse, options: .repeating, isActive: workspace.infoUnread)
                // The fill/outline swap above IS the unread signal — no hue is
                // introduced, so the pulse stays the only attention-grabbing
                // part. Full-strength `.primary` while unread keeps the filled
                // glyph reading as "on"; `.secondary` once seen matches every
                // other dimmed, read-state chip. `info.circle`/`.fill` share the
                // same SF Symbol metrics, so neither state shifts the chip.
                .foregroundStyle(workspace.infoUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // No capsule chrome on this chip — it is a bare icon, with the
                // unread state carried entirely by the glyph fill above. The
                // frame/padding/hit-shape below still live INSIDE the label so
                // the whole slot stays clickable and hoverable, not just the
                // glyph's own bounds (see the `title-capsule-hit-area` note — a
                // plain button's hit area is exactly its label's shape). The
                // fixed height matches `TitleCapsuleChrome`'s so this chip stays
                // vertically aligned with its capsule-chrome neighbours.
                .frame(height: 36)
                // Symmetric on purpose: this is the `.popover` source view's
                // bounds (the popover is attached to the Button below, and a
                // plain button's bounds are its label's bounds), so keeping it
                // centred on the glyph keeps the popover's arrow pointed at the
                // glyph. Only the small, glyph-hugging part of the hit-area
                // padding belongs here; the larger gap that separates this chip
                // from the diff counter is added past `.popover`, at the very
                // end of this modifier chain, where it can't skew this centring.
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Workspace info")
        .onHover { inside in scheduleHoverTransition(inside: inside) }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // The view is now always mounted, so `workspace.infoMarkdown` can be
            // nil while this closure exists (though never while presented — see
            // `reveal()`'s guard). Fall back to "" rather than force-unwrapping.
            WorkspaceInfoPanel(model: model, workspace: workspace, markdown: workspace.infoMarkdown ?? "")
                // Same transition as the button: entering cancels a pending
                // dismissal so the panel survives the trip from the button to
                // its content, and LEAVING re-arms one — otherwise the pointer
                // could wander off after that one grace period and strand the
                // popover open with nothing left to close it.
                .onHover { inside in scheduleHoverTransition(inside: inside) }
        }
        // The remaining teardown path: RootView keys `WorkspaceDetailView` on
        // the workspace id, so switching workspaces discards this exact button
        // instance outright, bypassing the animated hide entirely. `casper info
        // clear` no longer takes this path at all — the button stays mounted
        // and eases itself invisible via the `visible`-keyed modifiers below,
        // which is what the `onChange` below handles. Cancel + close here
        // anyway so a popover mid-presentation isn't left dangling on a source
        // view that is about to vanish. Running after `onChange` already reset
        // the same state is harmless — both are idempotent.
        .onDisappear {
            pendingHover?.cancel()
            isPresented = false
        }
        // Pure spacing, not hit area: pushes the chip away from the trailing
        // diff counter, and collapses to 0 with the chip so the diff counter
        // closes the gap instead of leaving a dead slot. Applied last, past
        // `.popover` above, so it can never become part of the popover's
        // source-view bounds — SwiftUI anchors a popover to the view it
        // modifies plus everything already applied to it, so any padding
        // placed before `.popover` in this chain would widen that anchor
        // asymmetrically and drag the arrow off the glyph. Folding this back
        // into the label's trailing padding (or anywhere before `.popover`)
        // would reintroduce exactly that bug.
        .padding(.trailing, visible ? 6 : 0)
        // Scale up from slightly small while fading in, and reverse the same
        // way going invisible, so the chip eases into the toolbar instead of
        // shoving its neighbours sideways with no warning. The width collapse
        // from `iconSlotWidth` down to `collapsedWidth` (not all the way to
        // 0) is what closes most of the gap for the neighbouring chips while
        // still leaving the small residual `collapsedWidth` slot — opacity
        // and scale alone would still reserve the full `iconSlotWidth` of
        // layout space while invisible.
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.6)
        .frame(width: visible ? Self.iconSlotWidth : Self.collapsedWidth)
        // Zero-width and zero-opacity is not automatically zero-interaction:
        // without this, the collapsed chip would still intercept clicks and
        // hover in the sliver of space it occupies mid-animation.
        .allowsHitTesting(visible)
        // Closes the popover the instant the message disappears, ahead of the
        // icon's own fade-out — without it, `casper info clear` followed by a
        // fresh `casper info set` would find a stale popover still open (or
        // still closing) from the previous message. Keyed on presence, like
        // the animation below, so this never fires just because the message
        // text changed.
        .onChange(of: workspace.infoMarkdown == nil) { _, isGone in
            guard isGone else { return }
            pendingHover?.cancel()
            isPresented = false
        }
        // Keyed on presence, not on the message text: republishing a different
        // message into an already-visible button must not replay the entrance
        // animation, only the appear/disappear edge should animate.
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: visible)
    }

    /// Schedules the reveal or dismissal that hovering the button or the popover
    /// both drive. Cancels whatever was previously pending — so a quick pass
    /// leaves no stale scheduled work — then, after the pointer settles for
    /// `hoverDelay` (entering) or `dismissGrace` (leaving), reveals or hides the
    /// panel. The two call sites (button, popover content) share this one
    /// implementation so "leaving re-arms dismissal" holds identically for both.
    private func scheduleHoverTransition(inside: Bool) {
        pendingHover?.cancel()
        pendingHover = Task { @MainActor in
            try? await Task.sleep(for: inside ? Self.hoverDelay : Self.dismissGrace)
            guard !Task.isCancelled else { return }
            if inside { reveal() } else { isPresented = false }
        }
    }

    private func reveal() {
        // The button is now always mounted, so a click can land after the icon
        // has already faded to invisible (`allowsHitTesting` should prevent
        // that, but this guard is what actually keeps the popover from ever
        // presenting with no message, rather than relying on layout alone).
        guard workspace.infoMarkdown != nil else { return }
        // A click can land while a hover-dwell reveal is still pending; cancel it
        // so it doesn't fire again a moment later on top of this one.
        pendingHover?.cancel()
        isPresented = true
        model.markInfoSeen(for: workspace.id)
    }
}
