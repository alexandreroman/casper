import AppKit
import SwiftUI

/// Hosts an EXISTING `NSView` in SwiftUI, re-parenting it into a fresh container
/// on each rebuild instead of creating a new one — keeps stateful views (a
/// terminal's PTY, a browser's navigation) alive across layout restructuring.
/// The view's lifetime is owned by the caller's cache, not by SwiftUI identity.
///
/// Because the hosted view is shared per surface, restructuring the split tree
/// (a collapse folding a split back to a single leaf, or a drag-relocate that
/// reparents the view into a different container) can momentarily leave several
/// containers pointing at it. Ownership is therefore driven by **window
/// membership**: `SharedHostContainer.viewDidMoveToWindow` re-evaluates on every
/// window transition and the single container currently in a window wins.
///
/// This supersedes the earlier one-shot `DispatchQueue.main.async` reconcile,
/// which bailed permanently when it ran before the winning container had entered
/// the window (`guard container.window != nil else { return }`, no retry) and so
/// left the shared view orphaned after a move. The window-driven coordinator is
/// robust to that timing: a move heals when the incoming container enters the
/// window, and a collapse heals when the outgoing container leaves it — each
/// transition simply re-runs the reconcile until it converges.
public struct PersistentNSViewHost: NSViewRepresentable {
    private let view: NSView
    public init(view: NSView) { self.view = view }

    public func makeNSView(context: Context) -> NSView {
        // Registration happens in the container's init.
        let container = SharedHostContainer(hostedView: view)
        // Handle the rare case the container is already in a window at creation.
        SharedViewOwnership.reconcile(view)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        // Re-converge if the structure changed without a window transition.
        // Let the coordinator decide the owner — do not unconditionally re-attach.
        SharedViewOwnership.reconcile(view)
    }
}

/// Container that reconciles shared-view ownership on every window transition.
@MainActor
final class SharedHostContainer: NSView {
    let hostedView: NSView

    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        SharedViewOwnership.register(self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Whether we just entered or left a window, re-evaluate who owns the
        // shared view: the one container currently in a window wins.
        SharedViewOwnership.reconcile(hostedView)
    }
}

/// Ownership registry keyed by the shared view identity. Converges the shared
/// view into whichever container is currently in a window.
@MainActor
enum SharedViewOwnership {
    // Weak container refs per hosted view; dead/removed containers (window == nil)
    // are naturally ignored at reconcile time.
    private static var registry: [ObjectIdentifier: NSHashTable<SharedHostContainer>] = [:]

    static func register(_ container: SharedHostContainer) {
        let key = ObjectIdentifier(container.hostedView)
        let table = registry[key] ?? NSHashTable<SharedHostContainer>.weakObjects()
        table.add(container)
        registry[key] = table
    }

    /// Place `view` into the single container that is currently in a window.
    /// If several are transiently in-window (mid-transition), any pick is fine:
    /// when the losers leave the window this runs again and converges.
    static func reconcile(_ view: NSView) {
        pruneEmptyTables()
        let key = ObjectIdentifier(view)
        guard let containers = registry[key]?.allObjects else { return }
        guard let winner = containers.first(where: { $0.window != nil }) else { return }
        if view.superview !== winner { place(view, in: winner) }
    }

    /// Drop registry entries whose tables have emptied out. The tables hold
    /// containers weakly, so a torn-down surface's containers vanish from their table
    /// but leave the now-empty table keyed by the (dead) hosted view — an unbounded
    /// accumulation over a long session. Pruning on each reconcile (which runs on
    /// every window transition) keeps the registry bounded.
    private static func pruneEmptyTables() {
        registry = registry.filter { !$0.value.allObjects.isEmpty }
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
