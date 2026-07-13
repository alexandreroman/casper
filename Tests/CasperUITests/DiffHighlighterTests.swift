import XCTest
@testable import CasperUI

final class DiffHighlighterTests: XCTestCase {
    func testSmallTextIsWithinHighlightBudget() {
        let small = String(repeating: "a", count: 1024)
        XCTAssertFalse(DiffHighlighter.exceedsHighlightBudget(small))
    }

    func testTextExceedingByteBudgetIsRejected() {
        let big = String(repeating: "a", count: DiffHighlighter.maxHighlightBytes + 1)
        XCTAssertTrue(DiffHighlighter.exceedsHighlightBudget(big))
    }
}
