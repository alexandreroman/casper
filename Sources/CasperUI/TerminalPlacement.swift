import CasperCore
import Foundation

/// Where `AppModel.insertTerminal` places a new terminal in a workspace's layout.
enum TerminalPlacement: Equatable {
    /// Split the workspace's first (top-left) surface, stacking the new terminal
    /// evenly below it — `casper terminal new`.
    case belowFirstSurface
    /// A full-width strip along the bottom of the workspace, taking
    /// `bottomStripFraction` of its height — a `.casper.json` script, whether a
    /// named command or the `setup` / `teardown` hook.
    case bottomStrip

    /// The share of the workspace's height a `.bottomStrip` terminal takes. Small
    /// enough that a script's output does not crowd out the panes already open.
    static let bottomStripFraction = 0.2

    /// `layout` with `surface` inserted at this placement, and the surface id that
    /// should hold focus — or nil when the layout has no surface to anchor on.
    func layout(inserting surface: Surface, into layout: LayoutNode) -> (LayoutNode, focus: UUID)? {
        switch self {
        case .belowFirstSurface:
            guard let anchor = LayoutTree.surfaceIDs(layout).first else { return nil }
            return LayoutTree.split(
                layout, focused: anchor, orientation: .vertical, side: .after, surface: surface)
        case .bottomStrip:
            return LayoutTree.appendBottomStrip(layout, surface: surface, fraction: Self.bottomStripFraction)
        }
    }
}
