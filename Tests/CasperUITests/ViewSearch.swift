import AppKit

/// The first view of type `T` in `view`'s subtree, `view` itself included.
/// Depth-first, so a hosted panel's own text view is found rather than any
/// scrollbar or chrome view that a SwiftUI `ScrollView` might add beside it.
@MainActor
func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let found = firstDescendant(type, in: subview) { return found }
    }
    return nil
}
