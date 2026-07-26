import SwiftUI

/// The body of the modal sheet shown while a workspace is being closed or
/// deleted: the operation title, a determinate bar with an `N of M` caption, and
/// the running step underneath.
///
/// Deliberately button-less — see the `.sheet` in `RootView` for why — so the
/// view is a pure function of its `progress` value and owns no state at all.
struct WorkspaceCloseProgressView: View {
    /// The sheet's fixed width. Fixed rather than content-driven so the sheet does
    /// not resize as steps — whose labels embed branch names of any length —
    /// succeed one another.
    static let width: CGFloat = 340

    let progress: WorkspaceCloseProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(progress.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView(value: Double(progress.stepIndex), total: Double(progress.stepCount))
                    Text("\(progress.stepIndex) of \(progress.stepCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                stepLabel
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Reserve both lines so the sheet keeps a fixed height as the
                    // steps — whose labels embed branch names of any length —
                    // succeed one another.
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: Self.width, alignment: .leading)
    }

    @ViewBuilder private var stepLabel: some View {
        if let deadline = progress.deadline {
            // A timeline redraw is the whole countdown mechanism: no timer to own,
            // nothing to invalidate when the step ends or the sheet goes away.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(progress.label) (\(Self.secondsLeft(until: deadline, now: context.date))s left)")
            }
        } else {
            Text(progress.label)
        }
    }

    /// Whole seconds until `deadline`, rounded up so the countdown reads `1s left`
    /// for the final second rather than sitting on `0s left`, and clamped at zero
    /// for the window between the deadline passing and the step being replaced.
    private static func secondsLeft(until deadline: Date, now: Date) -> Int {
        Int(max(0, deadline.timeIntervalSince(now)).rounded(.up))
    }
}
