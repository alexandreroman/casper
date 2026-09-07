import AppKit
import SwiftUI
import XCTest

/// The headless layout-measurement recipe the geometry suites in this target share:
/// host a real SwiftUI view in an `NSHostingView`, lay it out, and read the size it
/// settled on. No window, no run loop, no sleeps and no screen-recording permission
/// are involved — see the `headless-swiftui-layout-tests` note for what such a
/// measurement does and does not pin down.
extension XCTestCase {
    /// The size `view` lays out to when nothing constrains it.
    ///
    /// Hosted inside a `VStack(spacing: 0)` rather than bare, because a stack is what
    /// the shipping call sites provide: a body that is a `TupleView` of several
    /// elements is flattened by the parent stack, and hosted bare it would be
    /// flattened by whatever container semantics `NSHostingView` supplies instead —
    /// a different number from the one production gets. A view that needs no
    /// flattening measures the same either way.
    @MainActor
    func layoutSize(for view: some View) -> CGSize {
        let host = NSHostingView(rootView: VStack(spacing: 0) { view })
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The size `view` lays out to when it is proposed exactly `width` — the shape a
    /// truncation or wrapping assertion needs, where the width is the hostile input
    /// and the height is the answer.
    @MainActor
    func layoutSize(for view: some View, proposedWidth width: CGFloat) -> CGSize {
        layoutSize(for: view.frame(width: width))
    }

    /// The width `view` lays out to when nothing constrains it.
    @MainActor
    func layoutWidth(of view: some View) -> CGFloat {
        layoutSize(for: view).width
    }

    /// An SF Symbol's intrinsic width at `font`, measured on the SwiftUI `Image`
    /// rather than on `NSImage`: the two disagree at the same point size, so a slot
    /// sized from the wrong one lets the glyph overhang (see the
    /// `sf-symbol-widths-need-a-slot` note).
    @MainActor
    func symbolWidth(_ systemImage: String, font: Font? = nil) -> CGFloat {
        layoutWidth(of: Image(systemName: systemImage).font(font))
    }
}
