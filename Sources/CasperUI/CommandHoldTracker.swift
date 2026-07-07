import Foundation

/// A cancellable handle for a scheduled reveal timer, abstracting `Timer` so
/// `CommandHoldTracker` is testable without a real delay.
protocol HoldTimerToken: AnyObject {
    func cancel()
}

extension Timer: HoldTimerToken {
    func cancel() { invalidate() }
}

/// Turns Cmd key down/up transitions into a delayed "reveal" boolean: Cmd
/// must stay held for `holdDuration` before `onRevealChange(true)` fires;
/// releasing Cmd at any point — before or after the reveal — immediately
/// fires `onRevealChange(false)` and cancels any pending timer. Pure state
/// machine, no `NSEvent` dependency, so it's testable with an injected fake
/// scheduler (see `CommandHoldTrackerTests`).
@MainActor
final class CommandHoldTracker {
    private let holdDuration: TimeInterval
    private let scheduleTimer: (TimeInterval, @escaping () -> Void) -> HoldTimerToken
    private let onRevealChange: (Bool) -> Void
    private var pendingToken: HoldTimerToken?

    init(
        holdDuration: TimeInterval = 1.0,
        scheduleTimer: @escaping (TimeInterval, @escaping () -> Void) -> HoldTimerToken = { interval, fire in
            let timer = Timer(timeInterval: interval, repeats: false) { _ in fire() }
            // `.common` so the timer still fires while the run loop is in
            // event-tracking mode (e.g. a context menu is open).
            RunLoop.main.add(timer, forMode: .common)
            return timer
        },
        onRevealChange: @escaping (Bool) -> Void
    ) {
        self.holdDuration = holdDuration
        self.scheduleTimer = scheduleTimer
        self.onRevealChange = onRevealChange
    }

    func commandKeyDown() {
        guard pendingToken == nil else { return }
        pendingToken = scheduleTimer(holdDuration) { [weak self] in
            self?.pendingToken = nil
            self?.onRevealChange(true)
        }
    }

    func commandKeyUp() {
        pendingToken?.cancel()
        pendingToken = nil
        onRevealChange(false)
    }
}
