import Foundation

/// A snapshot of where a workspace close/delete has got to, published by
/// `AppModel` and rendered by `WorkspaceCloseProgressView`.
///
/// It is a plain value rather than an observable object so each step boundary is
/// one atomic assignment: the orchestrator never has to keep a live object in
/// sync, and the sheet is driven purely by identity plus equality.
struct WorkspaceCloseProgress: Identifiable, Equatable {
    /// The workspace being closed. Doubles as the `.sheet(item:)` identity, so a
    /// step update re-renders the existing sheet instead of re-presenting it.
    let id: UUID
    /// Prominent label, e.g. `Closing \u{201c}feature-x\u{201d}`.
    let title: String
    /// 1-based, so the bar is already partly filled while the first step runs.
    let stepIndex: Int
    let stepCount: Int
    /// The running step, e.g. `Merging \u{201c}feature\u{201d} into \u{201c}main\u{201d}\u{2026}`.
    let label: String
    /// When the running step will time out, or nil when it cannot. Only the
    /// teardown-hook step sets it; the view turns it into a live countdown, which
    /// is why the deadline travels as an absolute date rather than a duration —
    /// no timer state has to live in the model.
    let deadline: Date?
}
