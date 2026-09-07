import XCTest
@testable import CasperCore

final class ControlProtocolTests: XCTestCase {
    /// `ControlCommand` is a flat struct with a fully synthesized `Codable`, so a
    /// single round trip over a fixture that populates *every* field covers all
    /// verbs. `Equatable` compares every field, so the one assertion pins them all
    /// — a newly added field is only covered once it is set here too.
    func testCommandRoundTripsEveryField() throws {
        let command = ControlCommand(
            verb: .progressSet, workspace: "feature-x", state: "working",
            total: 5, current: 3, label: "wiring up",
            message: "## Ready\n- <http://localhost:8080>\n",
            url: "http://localhost:5173", target: "Sources/App.swift",
            branch: "feature-x", base: "main", command: "npm run dev",
            cwd: "/w", name: "test", script: "document.title", selector: "#submit",
            value: "hello", key: "Enter", path: "/tmp/shot.png", level: "warn",
            predicate: "document.readyState === 'complete'", waitTimeout: 2_000,
            clear: true, visible: true, gone: false, waitReady: true,
            width: 1280, height: 800)
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(ControlCommand.self, from: data), command)
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

    func testRunVerbRawValueIsStable() {
        XCTAssertEqual(ControlCommand.Verb.run.rawValue, "run")
    }

    func testInfoVerbRawValuesAreStable() {
        XCTAssertEqual(ControlCommand.Verb.infoSet.rawValue, "infoSet")
        XCTAssertEqual(ControlCommand.Verb.infoClear.rawValue, "infoClear")
    }
}
