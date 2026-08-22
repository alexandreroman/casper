import XCTest
@testable import CasperCore

final class AgentDetectionTests: XCTestCase {

    // MARK: - Viewport matcher

    private let rules = AgentDetectionRuleSet.claudeCode

    func testWorkingContainsEachInterruptHint() {
        XCTAssertEqual(rules.signal(fromViewport: "… esc to interrupt"), .working)
        XCTAssertEqual(rules.signal(fromViewport: "press esc to interrupt to stop"), .working)
        XCTAssertEqual(rules.signal(fromViewport: "ctrl+c to interrupt"), .working)
    }

    func testWorkingMatchesRunningToolsViewport() {
        let viewport = "Running tools…\n(esc to interrupt)"
        XCTAssertEqual(rules.signal(fromViewport: viewport), .working)
    }

    func testCodexWorkingMatchesItsInterruptAffordance() {
        XCTAssertEqual(
            AgentDetectionRuleSet.codex.signal(fromViewport: "Running tools…\n(esc to interrupt)"),
            .working)
    }

    func testCodexDoesNotTreatShellTitleAsAnExecutionSignal() {
        XCTAssertEqual(
            AgentDetectionRuleSet.codex.signal(fromTitle: "\u{2802} unrelated title"),
            .absent)
    }

    func testBlockedAllOfGroupRequiresEverySubstring() {
        let viewport = "Do you want to proceed?\n❯ Yes  (esc to cancel)"
        XCTAssertEqual(rules.signal(fromViewport: viewport), .blocked)
    }

    func testBlockedPartialGroupDoesNotMatch() {
        // Only one of the two required substrings ⇒ falls through to idle.
        XCTAssertEqual(rules.signal(fromViewport: "Do you want to proceed?"), .idle)
    }

    func testBlockedTakesPriorityOverWorking() {
        // Both affordances on screen at once: blocked must win.
        let viewport = "Do you want to proceed? (esc to cancel)\nesc to interrupt"
        XCTAssertEqual(rules.signal(fromViewport: viewport), .blocked)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(rules.signal(fromViewport: "ESC TO INTERRUPT"), .working)
        XCTAssertEqual(
            rules.signal(fromViewport: "DO YOU WANT TO PROCEED? (ESC TO CANCEL)"),
            .blocked)
    }

    func testPlainShellPromptIsIdle() {
        XCTAssertEqual(rules.signal(fromViewport: "alex@host ~/project % "), .idle)
    }

    func testMatcherNeverReturnsAbsent() {
        // Empty viewport still resolves to idle, never absent (caller owns absent).
        XCTAssertEqual(rules.signal(fromViewport: ""), .idle)
    }

    // MARK: - opencode rule set

    // Captured from opencode 1.18.20 running under `script` with
    // TERM_PROGRAM=ghostty / TERM_PROGRAM_VERSION=1.3.1, replayed into a grid.

    /// The footer row opencode writes for as long as a turn is running.
    private let opencodeWorkingFooter =
        "■⬝⬝⬝⬝⬝⬝⬝  esc interrupt                         tab agents  ctrl+p commands"

    /// A pending permission prompt. The working footer is still on screen beneath
    /// it, which is precisely the case `blocked` has to win.
    private let opencodePermissionPrompt = """
        ┃  △ Permission required
        ┃    # Shell command
        ┃  $ echo hello
        ┃   Allow once   Allow always   Reject  ctrl+f fullscreen  ⇆ select
        ■⬝⬝⬝⬝⬝⬝⬝  esc interrupt                         tab agents  ctrl+p commands
        """

    /// The at-rest footer that overwrites the working one when the turn ends.
    private let opencodeIdleFooter = "~/Projects/casper  12.4K/200K  ctrl+p commands"

    func testOpencodeInterruptFooterIsWorking() {
        // "esc interrupt" — no "to", so Claude Code's needles deliberately miss it.
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromViewport: opencodeWorkingFooter),
            .working)
        XCTAssertEqual(rules.signal(fromViewport: opencodeWorkingFooter), .idle)
    }

    func testOpencodePermissionPromptIsBlockedDespiteTheInterruptFooter() {
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromViewport: opencodePermissionPrompt),
            .blocked)
    }

    func testOpencodePermissionNeedsBothSubstrings() {
        // Either phrase alone (a chat message quoting it) must not read as blocked.
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromViewport: "┃  △ Permission required"),
            .idle)
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromViewport: "we could Allow once here"),
            .idle)
    }

    func testOpencodeAtRestFooterIsIdle() {
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromViewport: opencodeIdleFooter),
            .idle)
    }

    func testOpencodeTitleAssertsNothing() {
        // Plain ASCII, no glyph convention — the title is not a state source.
        XCTAssertEqual(AgentDetectionRuleSet.opencode.signal(fromTitle: "OpenCode"), .absent)
        XCTAssertEqual(
            AgentDetectionRuleSet.opencode.signal(fromTitle: "OC | Fix the detection tick"),
            .absent)
    }

    // MARK: - Rule-set union

    /// Mirrors what `runAgentDetectionTick` does: apply every rule set to the same
    /// viewport snapshot and keep the most urgent signal.
    private func unionViewportSignal(_ text: String) -> AgentSignal {
        AgentSignal.aggregate(AgentDetectionRuleSet.all.map { $0.signal(fromViewport: text) })
    }

    func testUnionClassifiesAnOpencodeWorkingFrameAsWorking() {
        // The regression this union fixes: with only the Claude Code rule set, a
        // running opencode turn read as idle for its whole duration.
        XCTAssertEqual(unionViewportSignal(opencodeWorkingFooter), .working)
    }

    func testUnionClassifiesAnOpencodePermissionPromptAsBlocked() {
        XCTAssertEqual(unionViewportSignal(opencodePermissionPrompt), .blocked)
    }

    func testUnionStillClassifiesTheOtherAgentsFrames() {
        XCTAssertEqual(unionViewportSignal("… esc to interrupt"), .working)
        XCTAssertEqual(unionViewportSignal("Running tools…"), .working)
        XCTAssertEqual(
            unionViewportSignal("Do you want to proceed?\n❯ Yes  (esc to cancel)"),
            .blocked)
    }

    func testUnionLeavesAPlainShellIdle() {
        XCTAssertEqual(unionViewportSignal("alex@host ~/project % "), .idle)
        XCTAssertEqual(unionViewportSignal(opencodeIdleFooter), .idle)
    }

    // MARK: - OSC-title matcher

    func testTitleBraillePrefixIsWorking() {
        XCTAssertEqual(rules.signal(fromTitle: "\u{2802} Doing something"), .working)
    }

    func testTitleBrailleRangeBoundaryIsWorking() {
        XCTAssertEqual(rules.signal(fromTitle: "\u{28FF} x"), .working)
    }

    func testTitleQuadrantCircleSpinnerIsWorking() {
        // Current Claude Code prints this spinner — captured from a real PTY session
        // (ESC]0;◐ Claude Code). The Braille range stays for older builds and other agents.
        XCTAssertEqual(rules.signal(fromTitle: "\u{25D0} Claude Code"), .working)
        XCTAssertEqual(rules.signal(fromTitle: "\u{25D1} Claude Code"), .working)
        XCTAssertEqual(rules.signal(fromTitle: "\u{25D2} Claude Code"), .working)
        XCTAssertEqual(rules.signal(fromTitle: "\u{25D3} Claude Code"), .working)
    }

    func testTitleScalarBetweenWorkingRangesIsAbsent() {
        // The two ranges must stay disjoint rather than collapse into one wide
        // catch-all: a scalar in the gap is not a spinner and must not read working.
        XCTAssertEqual(rules.signal(fromTitle: "\u{2700} x"), .absent)
    }

    func testTitleAsteriskPrefixIsIdle() {
        XCTAssertEqual(rules.signal(fromTitle: "\u{2733} Ready"), .idle)
    }

    func testPlainShellTitleIsAbsent() {
        XCTAssertEqual(rules.signal(fromTitle: "alex@host:/tmp/casper"), .absent)
    }

    func testEmptyTitleIsAbsent() {
        XCTAssertEqual(rules.signal(fromTitle: ""), .absent)
    }

    func testWhitespaceOnlyTitleIsAbsent() {
        XCTAssertEqual(rules.signal(fromTitle: "   "), .absent)
    }

    func testLeadingSpacesBeforeBrailleIsWorking() {
        XCTAssertEqual(rules.signal(fromTitle: "  \u{2802} x"), .working)
    }

    // MARK: - Progress report (OSC 9;4)

    func testProgressSetIsWorking() {
        // A determinate progress bar means an operation is running.
        XCTAssertEqual(AgentSignal(progress: .set), .working)
    }

    func testProgressIndeterminateIsWorking() {
        // What Claude Code emits for the whole duration of a turn (ESC]9;4;3),
        // verified against a real 2.1.239 PTY capture.
        XCTAssertEqual(AgentSignal(progress: .indeterminate), .working)
    }

    func testProgressRemovedIsAbsent() {
        // Absent, not idle: "this source says nothing", so a shell that never reports
        // progress stays indistinguishable from one that does, and the title/viewport
        // signals still decide.
        XCTAssertEqual(AgentSignal(progress: .removed), .absent)
    }

    func testProgressErrorIsAbsent() {
        // A red bar records the outcome of finished work, not liveness, and it lingers
        // until the next report — it must not pin the workspace to any state.
        XCTAssertEqual(AgentSignal(progress: .error), .absent)
    }

    func testProgressPausedIsAbsent() {
        // No agent Casper targets emits it, and a suspended bar asserts neither
        // liveness nor rest.
        XCTAssertEqual(AgentSignal(progress: .paused), .absent)
    }

    // MARK: - Aggregation

    func testAggregateEmptyIsAbsent() {
        XCTAssertEqual(AgentSignal.aggregate([]), .absent)
    }

    func testAggregateIdleBeatsAbsent() {
        XCTAssertEqual(AgentSignal.aggregate([.idle, .absent]), .idle)
    }

    func testAggregateWorkingBeatsIdle() {
        XCTAssertEqual(AgentSignal.aggregate([.working, .idle]), .working)
    }

    func testAggregateBlockedBeatsWorking() {
        XCTAssertEqual(AgentSignal.aggregate([.blocked, .working]), .blocked)
    }

    func testAggregateWorkingProgressRescuesIdleViewport() {
        // [viewport, title, progress]: the progress report is the only source that
        // still sees the run, so it must carry the workspace.
        XCTAssertEqual(AgentSignal.aggregate([.idle, .absent, .working]), .working)
    }

    func testAggregateRemovedProgressDoesNotVetoWorkingTitle() {
        // A silent progress source is absent, the weakest rank, so it cannot cancel
        // a working title.
        XCTAssertEqual(AgentSignal.aggregate([.idle, .working, .absent]), .working)
    }

    func testAggregateBlockedBeatsWorkingProgress() {
        // A pending question needs the user even while a progress bar is still up.
        XCTAssertEqual(AgentSignal.aggregate([.blocked, .absent, .working]), .blocked)
    }

    func testAggregateAllQuietIsIdle() {
        // Nothing reports work: idle outranks the two absent sources.
        XCTAssertEqual(AgentSignal.aggregate([.idle, .absent, .absent]), .idle)
    }

    // MARK: - Resolver

    func testWorkingSignalReportsWorking() {
        var resolver = AgentStateResolver()
        XCTAssertEqual(resolver.resolve(signal: .working, seen: false), .working)
    }

    func testBlockedSignalReportsBlocked() {
        var resolver = AgentStateResolver()
        XCTAssertEqual(resolver.resolve(signal: .blocked, seen: false), .blocked)
    }

    func testAbsentSignalReportsUnknown() {
        var resolver = AgentStateResolver()
        XCTAssertEqual(resolver.resolve(signal: .absent, seen: false), .unknown)
    }

    func testIdleFromTheStartIsIdleWithoutDebounce() {
        var resolver = AgentStateResolver()
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .idle)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .idle)
    }

    func testWorkingThenIdleUnseenDebouncesThenReportsDone() {
        var resolver = AgentStateResolver()
        XCTAssertEqual(resolver.resolve(signal: .working, seen: false), .working)
        // First idle tick is still within the debounce window ⇒ keeps reporting working.
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .working)
        // Second consecutive idle tick accepts the completion ⇒ done (unseen).
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .done)
    }

    func testDebounceOfOneReportsDoneOnFirstIdleTick() {
        var resolver = AgentStateResolver()
        _ = resolver.resolve(signal: .working, seen: false)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 1), .done)
    }

    func testWorkingThenIdleSeenReportsIdleNeverDone() {
        var resolver = AgentStateResolver()
        _ = resolver.resolve(signal: .working, seen: false)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: true, debounce: 2), .working)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: true, debounce: 2), .idle)
    }

    func testDonePersistsWhileUnseenAndFlipsToIdleWhenSeen() {
        var resolver = AgentStateResolver()
        _ = resolver.resolve(signal: .working, seen: false)
        _ = resolver.resolve(signal: .idle, seen: false, debounce: 2) // working (debounce)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .done)
        // Still unseen ⇒ the done latch holds.
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .done)
        // Seen ⇒ collapses to idle.
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: true, debounce: 2), .idle)
        // And stays idle thereafter.
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .idle)
    }

    func testWorkingAgainAfterDoneResetsTheLatch() {
        var resolver = AgentStateResolver()
        _ = resolver.resolve(signal: .working, seen: false)
        _ = resolver.resolve(signal: .idle, seen: false, debounce: 2)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .done)
        // A fresh working run must clear the latch and report working.
        XCTAssertEqual(resolver.resolve(signal: .working, seen: false), .working)
        // The following idle run debounces from scratch (not still-done).
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .working)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 2), .done)
    }

    func testWorkingClearsAnInProgressIdleDebounce() {
        var resolver = AgentStateResolver()
        _ = resolver.resolve(signal: .working, seen: false)
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 3), .working)
        // Work resumes mid-debounce; the idle streak must reset.
        XCTAssertEqual(resolver.resolve(signal: .working, seen: false), .working)
        // A single idle tick now is only the first of a fresh streak ⇒ still working.
        XCTAssertEqual(resolver.resolve(signal: .idle, seen: false, debounce: 3), .working)
    }
}
