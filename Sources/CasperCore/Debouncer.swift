import Foundation

/// A generic main-actor coalescing timer. Each `schedule` cancels the pending
/// work and arms a new one `delay` in the future, so a burst of calls fires the
/// action once. Mirrors `AppModel.scheduleSave`'s debounce idiom, extracted as a
/// reusable, model-free utility.
@MainActor
public final class Debouncer {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    isolated deinit {
        // Cancel any pending action so a coalesced fire cannot outlive the
        // Debouncer (and typically its owner), which would be surprising for a
        // reusable, model-free utility.
        pending?.cancel()
    }

    /// Cancel any pending action and arm `action` to fire `delay` from now.
    public func schedule(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
