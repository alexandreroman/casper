import Foundation

/// A generic main-actor coalescing timer. Each `schedule` cancels the pending
/// work and arms a new one `delay` in the future, so a burst of calls fires the
/// action once. A reusable, model-free utility: it holds nothing but the pending
/// work item, so one instance serves one coalesced concern.
@MainActor
public final class Debouncer {
    private let delay: TimeInterval
    // `nonisolated(unsafe)` is safe here: `pending` is only ever mutated from
    // `schedule` on the main actor, and by the time `deinit` runs no other
    // reference to the object exists, so there's no concurrent access to race
    // with (and `DispatchWorkItem.cancel()` is itself thread-safe). This lets
    // `deinit` read it without a main-actor hop — avoiding the `isolated deinit`
    // back-deployment shim that SIGABRTs on the CI runner.
    nonisolated(unsafe) private var pending: DispatchWorkItem?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    deinit {
        // Cancel any pending action so a coalesced fire cannot outlive the
        // Debouncer (and typically its owner), which would be surprising for a
        // reusable, model-free utility.
        pending?.cancel()
    }

    /// Cancel any pending action without firing it. What a caller that has to act
    /// *now* needs: cancel first, then do the work itself, so the coalesced fire
    /// cannot repeat it a moment later.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Cancel any pending action and arm `action` to fire `delay` from now.
    public func schedule(_ action: @escaping @MainActor () -> Void) {
        cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
