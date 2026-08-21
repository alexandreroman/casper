import XCTest
@testable import CasperCore

final class ControlTargetingTests: XCTestCase {
    private let candidates = [
        ControlWorkspaceInfo(id: "11111111-1111-1111-1111-111111111111", name: "main", branch: "main", path: "/main"),
        ControlWorkspaceInfo(id: "22222222-2222-2222-2222-222222222222", name: "feature", branch: "feature", path: "/feature"),
    ]

    func testMatchesByID() {
        XCTAssertEqual(
            ControlTargeting.match(selector: "22222222-2222-2222-2222-222222222222", candidates: candidates),
            "22222222-2222-2222-2222-222222222222")
    }

    func testMatchesByName() {
        XCTAssertEqual(ControlTargeting.match(selector: "feature", candidates: candidates),
                       "22222222-2222-2222-2222-222222222222")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(ControlTargeting.match(selector: "ghost", candidates: candidates))
    }

    /// An uppercase selector — a stale `$CASPER_WORKSPACE_ID` from an older build,
    /// or a user copy/paste — resolves against the canonical lowercase candidate.
    /// The literals spell out both cases rather than deriving one from the other,
    /// so a digit-only id can never make the assertion vacuous.
    func testMatchesUppercaseSelectorAgainstLowercaseCandidate() {
        let lowercase = [
            ControlWorkspaceInfo(id: "abcdef01-abcd-4bcd-8bcd-abcdef012345", name: "main",
                                 branch: "main", path: "/main"),
        ]
        XCTAssertEqual(
            ControlTargeting.match(selector: "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345", candidates: lowercase),
            "abcdef01-abcd-4bcd-8bcd-abcdef012345")
    }

    /// The mirror case: a candidate minted by an older build is still targetable by
    /// the lowercase id the current CLI passes.
    func testMatchesLowercaseSelectorAgainstUppercaseCandidate() {
        let uppercase = [
            ControlWorkspaceInfo(id: "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345", name: "main",
                                 branch: "main", path: "/main"),
        ]
        XCTAssertEqual(
            ControlTargeting.match(selector: "abcdef01-abcd-4bcd-8bcd-abcdef012345", candidates: uppercase),
            "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345")
    }

    /// Id match still wins over name match, even when only the id's case differs.
    func testIDMatchWinsOverNameMatch() {
        let ambiguous = [
            ControlWorkspaceInfo(id: "abcdef01-abcd-4bcd-8bcd-abcdef012345", name: "main",
                                 branch: "main", path: "/main"),
            ControlWorkspaceInfo(id: "22222222-2222-2222-2222-222222222222",
                                 name: "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345",
                                 branch: "feature", path: "/feature"),
        ]
        XCTAssertEqual(
            ControlTargeting.match(selector: "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345", candidates: ambiguous),
            "abcdef01-abcd-4bcd-8bcd-abcdef012345")
    }

    /// The name match stays exact, so a differently-cased name is not a target.
    func testNameMatchIsCaseSensitive() {
        XCTAssertNil(ControlTargeting.match(selector: "FEATURE", candidates: candidates))
    }
}
