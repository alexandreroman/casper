import Foundation

/// Drives the modal progress sheet for one workspace close/delete run — and hides the
/// fast ones.
///
/// The orchestrator reports every step boundary here from the very first instant, but a
/// close that is over in a few milliseconds must not flash a panel on screen. So this
/// keeps the live value to itself until the operation has been running for `delay`; only
/// then is it promoted to the published value, and only from then on does each further
/// step write through. `finish` cancels the pending promotion, so an operation that ends
/// before the delay elapses publishes nothing at all.
///
/// The published value is shared by every operation, and only one sheet can be on screen,
/// so this reporter owns it **by identity**: it writes and clears only while the published
/// value carries its own workspace id (or is free). An operation therefore never steals a
/// live sheet from a concurrent one, and — the case that actually mattered — never
/// dismisses one, which would have shown "done" while a repository was still being
/// written.
///
/// Everything is `@MainActor`-isolated, which is what makes that race trivial: the
/// promotion task's body and `finish` are both main-actor work items, so they cannot
/// interleave. Either `finish` cancels first and the promotion returns early, or the
/// promotion has already run and `finish` takes the sheet back down.
///
/// It lives here rather than inside `AppModel` — which is already large — because the
/// delay, the write-through and the step numbering are one self-contained concern.
@MainActor
final class WorkspaceCloseProgressReporter {
    /// How long an operation must run before its sheet is allowed to appear.
    static let presentationDelay: Duration = .milliseconds(250)

    private let id: UUID
    private let title: String
    private let stepCount: Int
    private let delay: Duration
    private let publish: (WorkspaceCloseProgress?) -> Void
    private let published: () -> WorkspaceCloseProgress?
    private let onStep: (WorkspaceCloseProgress) -> Void

    /// The latest step, tracked whether or not the sheet is visible — it is what the
    /// promotion publishes when the delay elapses.
    private var current: WorkspaceCloseProgress?
    /// 1-based once the first `step` lands. `step` advances it, so a conditional step is
    /// skipped simply by not calling `step` — no index arithmetic at the call site.
    private var stepIndex = 0
    /// True once the delay has elapsed, which is the permission to write through to the
    /// shared published value. Whether that write actually lands is a separate question,
    /// settled by ownership in `publishIfUnowned`.
    private var delayElapsed = false

    /// The pending promotion. Internal (rather than private) so a test can await it
    /// instead of sleeping; production code only ever cancels it.
    private(set) var promotion: Task<Void, Never>?

    /// `delay` is injectable purely so tests can drive the visible path without sleeping;
    /// every production call site takes the default.
    init(
        id: UUID,
        title: String,
        stepCount: Int,
        delay: Duration = WorkspaceCloseProgressReporter.presentationDelay,
        publish: @escaping (WorkspaceCloseProgress?) -> Void,
        published: @escaping () -> WorkspaceCloseProgress?,
        onStep: @escaping (WorkspaceCloseProgress) -> Void
    ) {
        self.id = id
        self.title = title
        self.stepCount = stepCount
        self.delay = delay
        self.publish = publish
        self.published = published
        self.onStep = onStep
    }

    /// Begin the operation. The delay countdown starts here rather than at the first
    /// step, so it measures the whole run.
    func start() {
        let delay = self.delay
        promotion = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            delayElapsed = true
            if let current { publishIfUnowned(current) }
        }
    }

    /// Advance to the next step. `deadline` is set only by a step that can time out — the
    /// teardown hook — and drives the sheet's countdown.
    func step(_ label: String, deadline: Date? = nil) {
        stepIndex += 1
        let progress = WorkspaceCloseProgress(
            id: id, title: title, stepIndex: stepIndex, stepCount: stepCount,
            label: label, deadline: deadline)
        current = progress
        if delayElapsed { publishIfUnowned(progress) }
        // Unconditional, and after the write-through: tests observe the real step
        // sequence without waiting out the delay or instantiating a view.
        onStep(progress)
    }

    /// End the operation: cancel any pending promotion and take our own sheet down.
    /// Idempotent, so it is safe to call from a `defer` covering every exit path.
    func finish() {
        promotion?.cancel()
        promotion = nil
        current = nil
        delayElapsed = false
        // Clear only what we published. A run that never became visible, or whose sheet
        // was never shown because another operation owned the screen, must leave the
        // shared value alone — otherwise it would dismiss that other operation's sheet
        // while its repository work is still running.
        guard published()?.id == id else { return }
        publish(nil)
    }

    /// Publish `progress` unless another operation currently owns the sheet. Retried on
    /// every step, so a run that lost the race still gets its sheet as soon as the other
    /// operation clears the value.
    private func publishIfUnowned(_ progress: WorkspaceCloseProgress) {
        let shown = published()
        guard shown == nil || shown?.id == id else { return }
        publish(progress)
    }
}
