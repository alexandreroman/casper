import AppKit
import CasperCore
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
        #if DEBUG
        LiveObjectCensus.track(self)
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Whether we just entered or left a window, re-evaluate who owns the
        // shared view: the one container currently in a window wins.
        SharedViewOwnership.reconcile(hostedView)
        // A torn-down surface leaves the window here, emptying its table — prune
        // on this transition so the registry stays bounded (see pruneEmptyTables).
        SharedViewOwnership.pruneEmptyTables()
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
        guard let containers = registry[ObjectIdentifier(view)] else { return }
        // Enumerate the table lazily and stop at the first in-window container.
        // `allObjects` would bridge a fresh Array out of the table on every call, and
        // this runs from `updateNSView` — i.e. on every SwiftUI state change, not just
        // the structural ones that can actually move the shared view.
        for case let winner as SharedHostContainer in containers.objectEnumerator()
        where winner.window != nil {
            if view.superview !== winner { place(view, in: winner) }
            return
        }
    }

    /// Drop registry entries whose tables have emptied out. The tables hold
    /// containers weakly, so a torn-down surface's containers vanish from their table
    /// but leave the now-empty table keyed by the (dead) hosted view — an unbounded
    /// accumulation over a long session. This runs only on window transitions (from
    /// `viewDidMoveToWindow`), which is exactly when a torn-down container leaves its
    /// table empty, so the registry stays bounded without paying the sweep cost on the
    /// `updateNSView`/reconcile hot path (which fires on every SwiftUI update).
    ///
    /// The sweep has to cover the whole registry, not just the transitioning
    /// container's own key: a container is still alive while its own
    /// `viewDidMoveToWindow` runs, so its table is never empty at that point. An entry
    /// only empties out once its last container has deallocated, which some *other*
    /// container's later transition is what observes. It stays cheap by collecting dead
    /// keys first — no dictionary rebuild — and by testing emptiness through the
    /// enumerator rather than `allObjects`, which would bridge a fresh `Array` out of
    /// every live surface's table.
    ///
    /// Emptiness is not tested with `count`: `NSHashTable.count` is documented as
    /// unreliable for weak tables (it can still report entries whose objects have been
    /// deallocated but not yet cleared). The enumerator yields only live objects, which
    /// is what `reconcile` above already relies on.
    static func pruneEmptyTables() {
        let emptyKeys = registry.compactMap { key, table in
            table.objectEnumerator().nextObject() == nil ? key : nil
        }
        for key in emptyKeys {
            registry.removeValue(forKey: key)
        }
    }

    #if DEBUG
    /// Registry size and the live container population, for the memory census.
    ///
    /// Counted through the enumerator, never `NSHashTable.count`, for the reason
    /// `pruneEmptyTables` documents: a weak table's `count` can still report entries
    /// whose objects have already deallocated.
    static func debugCounts() -> (registryEntries: Int, containers: Int) {
        var containers = 0
        for table in registry.values {
            let enumerator = table.objectEnumerator()
            while enumerator.nextObject() != nil { containers += 1 }
        }
        return (registry.count, containers)
    }
    #endif
}

#if DEBUG
/// Reads `CasperGhostty`'s internal shared-view registry for the debug memory
/// census. It exists only because `SharedViewOwnership` is internal to this
/// module and the census is assembled in `CasperUI`.
@MainActor
public enum GhosttyDebugCensus {
    /// The number of registry entries (one per shared view still keyed) and the
    /// total number of live containers across all of them. Both should return to
    /// the pre-churn level once terminals are closed.
    public static var sharedViewCounts: (registryEntries: Int, containers: Int) {
        SharedViewOwnership.debugCounts()
    }
}
#endif

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
