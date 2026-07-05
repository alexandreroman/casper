import XCTest
@testable import CasperCore

final class ControlTargetingTests: XCTestCase {
    private let candidates = [
        ControlWorkspaceInfo(id: "11111111-1111-1111-1111-111111111111", name: "main", branch: "main"),
        ControlWorkspaceInfo(id: "22222222-2222-2222-2222-222222222222", name: "feature", branch: "feature"),
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
}
