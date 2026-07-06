import XCTest
@testable import CasperCLI

/// Covers the pure JSON formatting seam (`jsonLine`) — the exact strings the CLI
/// prints on stdout/stderr, including `sortedKeys` ordering, explicit `null`, and
/// slash/quote escaping.
final class JSONOutputTests: XCTestCase {
    func testStatus() {
        XCTAssertEqual(
            jsonLine(StatusOut(status: "waiting", workspace: "W")),
            #"{"status":"waiting","workspace":"W"}"#)
    }

    func testProgressBody() {
        XCTAssertEqual(
            jsonLine(ProgressOut(
                progress: ProgressBody(total: 3, current: 1, label: "wire"), workspace: "W")),
            #"{"progress":{"current":1,"label":"wire","total":3},"workspace":"W"}"#)
    }

    func testWorkspaceRef() {
        XCTAssertEqual(jsonLine(WorkspaceRefOut(workspace: "W")), #"{"workspace":"W"}"#)
    }

    func testWorkspaceNew() {
        XCTAssertEqual(
            jsonLine(WorkspaceNewOut(workspace: "i", name: "n", branch: "b", path: "p")),
            #"{"branch":"b","name":"n","path":"p","workspace":"i"}"#)
    }

    func testTerminalNew() {
        XCTAssertEqual(
            jsonLine(TerminalNewOut(workspace: "W", command: nil, cwd: nil)),
            #"{"workspace":"W"}"#)
        XCTAssertEqual(
            jsonLine(TerminalNewOut(workspace: "W", command: "c", cwd: "d")),
            #"{"command":"c","cwd":"d","workspace":"W"}"#)
        XCTAssertEqual(
            jsonLine(TerminalNewOut(workspace: "W", command: "c", cwd: nil)),
            #"{"command":"c","workspace":"W"}"#)
    }

    func testWorkspaceArray() {
        XCTAssertEqual(
            jsonLine([WorkspaceOut(id: "i", name: "n", branch: "b", path: "p")]),
            #"[{"branch":"b","id":"i","name":"n","path":"p"}]"#)
    }

    func testCurrent() {
        XCTAssertEqual(
            jsonLine(CurrentOut(workspace: "i", path: "p")),
            #"{"path":"p","workspace":"i"}"#)
        XCTAssertEqual(
            jsonLine(CurrentOut(workspace: "i", path: nil)),
            #"{"workspace":"i"}"#)
    }

    func testErrorEscaping() {
        XCTAssertEqual(jsonLine(ErrorOut(error: #"bad "x""#)), #"{"error":"bad \"x\""}"#)
    }
}
