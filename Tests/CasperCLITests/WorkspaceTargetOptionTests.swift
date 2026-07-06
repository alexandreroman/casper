import XCTest
@testable import CasperCLI

final class WorkspaceTargetOptionTests: XCTestCase {
    func testFlagWins() {
        var opt = WorkspaceTargetOption()
        opt.workspace = "flagged"
        XCTAssertEqual(opt.resolvedSelector(environment: ["CASPER_WORKSPACE_ID": "env-id"]), "flagged")
    }

    func testEnvFallback() {
        let opt = WorkspaceTargetOption()
        XCTAssertEqual(opt.resolvedSelector(environment: ["CASPER_WORKSPACE_ID": "env-id"]), "env-id")
    }

    func testNoneIsNil() {
        let opt = WorkspaceTargetOption()
        XCTAssertNil(opt.resolvedSelector(environment: [:]))
    }
}
