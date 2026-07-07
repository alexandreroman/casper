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
    /// A single hold moves idle → pending → revealed, and any release snaps it
    /// back to idle. Modelling all three states (rather than a lone
    /// `pendingToken`) lets `commandKeyDown()` stay a no-op both while the timer
    /// is pending *and* after it has fired, so a stray key-down mid-hold — e.g.
    /// an unrelated modifier's `flagsChanged` while Cmd is still held — can't
    /// re-arm the timer or reveal twice for the same hold.
    private enum State {
        case idle
        case pending(HoldTimerToken)
        case revealed
    }

    private let holdDuration: TimeInterval
    private let scheduleTimer: (TimeInterval, @escaping () -> Void) -> HoldTimerToken
    private let onRevealChange: (Bool) -> Void
    private var state: State = .idle

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
        guard case .idle = state else { return }
        state = .pending(scheduleTimer(holdDuration) { [weak self] in
            self?.state = .revealed
            self?.onRevealChange(true)
        })
    }

    func commandKeyUp() {
        if case .idle = state { return }
        if case .pending(let token) = state {
            token.cancel()
        }
        state = .idle
        onRevealChange(false)
    }
}
