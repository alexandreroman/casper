import XCTest
@testable import CasperCore

final class ControlProtocolTests: XCTestCase {
    func testCommandRoundTripsThroughJSON() throws {
        let command = ControlCommand(
            verb: .progressSet, workspace: "feature-x",
            total: 5, current: 3, label: "wiring up")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.verb, .progressSet)
    }

    func testVerbRawValuesAreStable() {
        XCTAssertEqual(ControlCommand.Verb.statusSet.rawValue, "statusSet")
        XCTAssertEqual(ControlCommand.Verb.workspaceNew.rawValue, "workspaceNew")
    }

    func testResponseFactories() throws {
        let ok = ControlResponse.success(text: "id-1")
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.text, "id-1")
        let bad = ControlResponse.failure("nope")
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "nope")
    }

    func testWorkspaceInfoRoundTrips() throws {
        let info = ControlWorkspaceInfo(id: "u", name: "n", branch: "b", path: "p")
        let data = try JSONEncoder().encode(ControlResponse.success(workspaces: [info]))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(decoded.workspaces, [info])
    }
}
