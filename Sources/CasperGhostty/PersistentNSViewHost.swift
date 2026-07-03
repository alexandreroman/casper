import AppKit
import SwiftUI

/// Hosts an EXISTING `NSView` in SwiftUI, re-parenting it into a fresh container
/// on each rebuild instead of creating a new one — keeps stateful views (a
/// terminal's PTY, a browser's navigation) alive across layout restructuring.
/// The view's lifetime is owned by the caller's cache, not by SwiftUI identity.
///
/// Because the hosted view is shared per surface, a layout collapse (a split
/// folding back to a single leaf) can momentarily leave two hosts fighting over
/// it. Each attach schedules a next-runloop, window-guarded reconcile so the
/// view ends up owned by the host whose container actually stays in the window.
public struct PersistentNSViewHost: NSViewRepresentable {
    private let view: NSView
    public init(view: NSView) { self.view = view }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        place(view, in: container)
        // Ownership tie-break for a shared view. During a layout collapse the outgoing
        // host can steal the view into a container that SwiftUI is about to remove from
        // the window. On the next runloop turn only a host whose container is still in a
        // window keeps the view; the surviving host re-claims it if it was stolen, and a
        // stale host (its container already out of the window) yields.
        let view = self.view
        DispatchQueue.main.async {
            guard container.window != nil else { return }
            if view.superview !== container { place(view, in: container) }
        }
    }
}

@MainActor
private func place(_ view: NSView, in container: NSView) {
    view.removeFromSuperview()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}
