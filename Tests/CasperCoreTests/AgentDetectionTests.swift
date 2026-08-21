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

    // MARK: - OSC-title matcher

    func testTitleBraillePrefixIsWorking() {
        XCTAssertEqual(rules.signal(fromTitle: "\u{2802} Doing something"), .working)
    }

    func testTitleBrailleRangeBoundaryIsWorking() {
        XCTAssertEqual(rules.signal(fromTitle: "\u{28FF} x"), .working)
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
