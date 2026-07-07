import Foundation

/// A shared reference point so independently-created SwiftUI views (e.g. one
/// per sidebar row) can animate in phase with each other, without a
/// continuously-invalidating clock. Each view computes `phaseDelay(period:)`
/// once when it appears and passes it to its own `.animation(...).delay(...)`
/// modifier, so the animation behaves as if it started at `epoch` regardless
/// of when this particular instance actually appeared.
enum AnimationClock {
    static let epoch = Date()

    /// A negative delay, in `(-period, 0]`, that phase-aligns a
    /// `repeatForever` animation of the given `period` (the full cycle
    /// length — `duration` for `autoreverses: false`, `2 * duration` for
    /// `autoreverses: true`) to `epoch`.
    static func phaseDelay(period: TimeInterval, now: Date = Date(), epoch: Date = AnimationClock.epoch) -> Double {
        let elapsed = max(0, now.timeIntervalSince(epoch))
        return -elapsed.truncatingRemainder(dividingBy: period)
    }
}
