import AppKit
import SwiftUI

/// Hosts an EXISTING `GhosttySurfaceView` in SwiftUI, re-parenting it into a
/// fresh container on each rebuild instead of creating a new surface. This keeps
/// the underlying libghostty surface (and its PTY) alive across layout
/// restructuring — the surface view's lifetime is owned by the caller's cache,
/// not by SwiftUI's view identity.
public struct GhosttySurfaceHostView: NSViewRepresentable {
    private let surfaceView: GhosttySurfaceView

    public init(surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if surfaceView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        surfaceView.removeFromSuperview()
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: container.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
