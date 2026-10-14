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

    /// The verbs' wire names are a contract with every client of the control
    /// socket, so each one is spelled out rather than derived from the enum.
    func testVerbWireNamesAreStable() {
        let wireNames = [
            "statusSet", "statusGet", "progressSet", "progressClear", "progressGet", "notify",
            "infoSet", "infoClear", "terminalNew", "terminalList", "terminalClose",
            "browserOpen", "browserLoad", "browserClose", "diffOpen", "diffClose",
            "workspaceList", "workspaceNew", "workspaceDelete", "run",
            "browserScreenshot", "browserEval", "browserContent", "browserURL", "browserClick",
            "browserType", "browserKey", "browserConsole", "browserWait", "browserReload",
            "browserScrollUp", "browserScrollDown", "browserScrollTop", "browserScrollBottom",
        ]
        for name in wireNames {
            XCTAssertNotNil(ControlCommand.Verb(rawValue: name), "no verb answers to '\(name)'")
        }
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

    func testAbsoluteURLRequiresSchemeAndHost() {
        XCTAssertEqual(ControlCommand.absoluteURL("https://example.com/a")?.host, "example.com")
        XCTAssertEqual(ControlCommand.absoluteURL("http://localhost:5173")?.port, 5173)
        XCTAssertNil(ControlCommand.absoluteURL(nil))
        XCTAssertNil(ControlCommand.absoluteURL(""))
        XCTAssertNil(ControlCommand.absoluteURL("example.com"))
        XCTAssertNil(ControlCommand.absoluteURL("/tmp/page.html"))
        XCTAssertNil(ControlCommand.absoluteURL("file:///tmp/page.html"))
    }

    func testUnwrappedJSONStringUnwrapsStringButNotOtherTokens() {
        // `eval --raw`, `content` and `url` unwrap a JSON string to its bare
        // contents, but leave numbers, booleans, null, and containers as-is.
        XCTAssertEqual(ControlResponse.unwrappedJSONString("\"My Title\""), "My Title")
        XCTAssertEqual(ControlResponse.unwrappedJSONString("42"), "42")
        XCTAssertEqual(ControlResponse.unwrappedJSONString("true"), "true")
        XCTAssertEqual(ControlResponse.unwrappedJSONString("null"), "null")
        XCTAssertEqual(ControlResponse.unwrappedJSONString("{\"a\":1}"), "{\"a\":1}")
    }
}
