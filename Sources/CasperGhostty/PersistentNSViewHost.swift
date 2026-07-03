import AppKit
import SwiftUI

/// Hosts an EXISTING `NSView` in SwiftUI, re-parenting it into a fresh container
/// on each rebuild instead of creating a new one — keeps stateful views (a
/// terminal's PTY, a browser's navigation) alive across layout restructuring.
/// The view's lifetime is owned by the caller's cache, not by SwiftUI identity.
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
}
