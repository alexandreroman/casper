import XCTest
@testable import CasperUI

/// Direct coverage of the reporter's two rules — the anti-flash delay and the
/// ownership of the shared published value — with no model, no view and no sleeping.
///
/// `CloseDeleteWorkspaceTests` exercises the same reporter end-to-end through a real
/// close, but only over the step sequence: whether the sheet appears depends there on
/// how fast the machine runs the git work, which is exactly what must not decide
/// whether an assertion runs.
@MainActor
final class WorkspaceCloseProgressReporterTests: XCTestCase {
    /// A reporter wired to `published`, standing in for `AppModel.closeProgress`.
    ///
    /// `delay: .zero` makes the promotion land on the very next scheduling turn, which
    /// `await reporter.promotion?.value` then waits for deterministically. The default
    /// delay is used where the point is that the promotion does NOT land.
    private func makeReporter(
        id: UUID, title: String = "Closing \u{201c}feature\u{201d}", stepCount: Int = 2,
        delay: Duration = WorkspaceCloseProgressReporter.presentationDelay,
        published: @escaping () -> WorkspaceCloseProgress?,
        publish: @escaping (WorkspaceCloseProgress?) -> Void
    ) -> WorkspaceCloseProgressReporter {
        WorkspaceCloseProgressReporter(
            id: id, title: title, stepCount: stepCount, delay: delay,
            publish: publish, published: published, onStep: { _ in })
    }

    /// The anti-flash rule: an operation that runs its whole course before the delay
    /// elapses must never touch the published value — not even to clear it.
    func testARunThatEndsBeforeTheDelayNeverPublishes() async {
        var shown: WorkspaceCloseProgress?
        var writes = 0
        let reporter = makeReporter(
            id: UUID(), published: { shown }, publish: { shown = $0; writes += 1 })

        // No `await` anywhere in the run, so the promotion task cannot have run: this is
        // the fast close, without depending on how fast the machine is.
        reporter.start()
        let promotion = reporter.promotion
        reporter.step("Checking for uncommitted changes\u{2026}")
        reporter.step("Removing the worktree\u{2026}")
        reporter.finish()
        _ = await promotion?.value

        XCTAssertEqual(writes, 0, "a fast close must not flash a sheet, nor clear one")
        XCTAssertNil(shown)
    }

    /// Past the delay, the sheet appears and every later step writes through.
    func testPromotionPublishesTheCurrentStepAndLaterStepsWriteThrough() async {
        var shown: WorkspaceCloseProgress?
        let workspaceID = UUID()
        let reporter = makeReporter(
            id: workspaceID, delay: .zero, published: { shown }, publish: { shown = $0 })

        reporter.start()
        reporter.step("Checking for uncommitted changes\u{2026}")
        await reporter.promotion?.value

        XCTAssertEqual(shown?.id, workspaceID)
        XCTAssertEqual(shown?.label, "Checking for uncommitted changes\u{2026}")
        XCTAssertEqual(shown?.stepIndex, 1)

        reporter.step("Removing the worktree\u{2026}")
        XCTAssertEqual(shown?.label, "Removing the worktree\u{2026}", "a visible sheet follows the steps")
        XCTAssertEqual(shown?.stepIndex, 2)

        reporter.finish()
        XCTAssertNil(shown, "its own sheet comes down when the operation ends")
    }

    /// Ownership, the case that matters: a second operation must neither take over the
    /// live sheet of the first nor — the real defect — dismiss it on its way out, which
    /// would have told the user "done" while a repository was still being written.
    func testASecondOperationNeitherStealsNorDismissesALiveSheet() async {
        var shown: WorkspaceCloseProgress?
        let firstID = UUID()
        let secondID = UUID()
        let first = makeReporter(
            id: firstID, delay: .zero, published: { shown }, publish: { shown = $0 })
        let second = makeReporter(
            id: secondID, title: "Deleting \u{201c}other\u{201d}", delay: .zero,
            published: { shown }, publish: { shown = $0 })

        first.start()
        first.step("Merging\u{2026}")
        await first.promotion?.value
        XCTAssertEqual(shown?.id, firstID, "the first operation owns the sheet")

        second.start()
        second.step("Running teardown hook\u{2026}")
        await second.promotion?.value
        XCTAssertEqual(shown?.id, firstID, "the second must not take the screen from the first")

        second.finish()
        XCTAssertEqual(shown?.id, firstID, "and must not take the first operation's sheet down")

        first.finish()
        XCTAssertNil(shown, "only the owner clears the published value")
    }

    /// The mirror image: once the owner is gone, a still-running operation claims the
    /// sheet at its next step rather than staying invisible for the rest of its run.
    func testAnOperationClaimsTheSheetOnceItIsFree() async {
        var shown: WorkspaceCloseProgress?
        let firstID = UUID()
        let secondID = UUID()
        let first = makeReporter(
            id: firstID, delay: .zero, published: { shown }, publish: { shown = $0 })
        let second = makeReporter(
            id: secondID, title: "Deleting \u{201c}other\u{201d}", delay: .zero,
            published: { shown }, publish: { shown = $0 })

        first.start()
        first.step("Merging\u{2026}")
        await first.promotion?.value
        second.start()
        second.step("Running teardown hook\u{2026}")
        await second.promotion?.value
        first.finish()

        second.step("Removing the worktree\u{2026}")

        XCTAssertEqual(shown?.id, secondID, "the freed sheet goes to the operation still running")
        XCTAssertEqual(shown?.label, "Removing the worktree\u{2026}")
    }
}
