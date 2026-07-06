import XCTest
@testable import CasperCLI

final class WorkspaceTargetOptionTests: XCTestCase {
    func testFlagWins() throws {
        let opt = try WorkspaceTargetOption.parse(["--workspace", "flagged"])
        XCTAssertEqual(opt.resolvedSelector(environment: ["CASPER_WORKSPACE_ID": "env-id"]), "flagged")
    }

    func testEnvFallback() throws {
        let opt = try WorkspaceTargetOption.parse([])
        XCTAssertEqual(opt.resolvedSelector(environment: ["CASPER_WORKSPACE_ID": "env-id"]), "env-id")
    }

    func testNoneIsNil() throws {
        let opt = try WorkspaceTargetOption.parse([])
        XCTAssertNil(opt.resolvedSelector(environment: [:]))
    }
}
