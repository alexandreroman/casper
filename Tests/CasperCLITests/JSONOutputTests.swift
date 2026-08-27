import XCTest
@testable import CasperCLI

/// Covers the pure JSON formatting seam (`jsonLine`) — the exact strings the CLI
/// prints on stdout/stderr, including `sortedKeys` ordering, explicit `null`, and
/// slash/quote escaping.
final class JSONOutputTests: XCTestCase {
    func testStatus() {
        XCTAssertEqual(
            jsonLine(StatusOut(status: "blocked", workspace: "W")),
            #"{"status":"blocked","workspace":"W"}"#)
    }

    func testProgressBody() {
        XCTAssertEqual(
            jsonLine(ProgressOut(
                progress: ProgressBody(total: 3, current: 1, label: "wire"), workspace: "W")),
            #"{"progress":{"current":1,"label":"wire","total":3},"workspace":"W"}"#)
    }

    /// `progress get` prints an explicit `null` for "no bar up" rather than
    /// dropping the key: absence is the answer, not a missing field.
    func testProgressGet() {
        XCTAssertEqual(
            jsonLine(ProgressGetOut(
                progress: ProgressBody(total: 3, current: 2, label: "wire"), workspace: "W")),
            #"{"progress":{"current":2,"label":"wire","total":3},"workspace":"W"}"#)
        XCTAssertEqual(
            jsonLine(ProgressGetOut(progress: nil, workspace: "W")),
            #"{"progress":null,"workspace":"W"}"#)
    }

    func testWorkspaceRef() {
        XCTAssertEqual(jsonLine(WorkspaceRefOut(workspace: "W")), #"{"workspace":"W"}"#)
    }

    func testWorkspaceNew() {
        XCTAssertEqual(
            jsonLine(WorkspaceNewOut(workspace: "i", name: "n", branch: "b", path: "p", command: "npm test")),
            #"{"branch":"b","command":"npm test","name":"n","path":"p","workspace":"i"}"#)
        XCTAssertEqual(
            jsonLine(WorkspaceNewOut(workspace: "i", name: "n", branch: nil, path: "p", command: nil)),
            #"{"name":"n","path":"p","workspace":"i"}"#)
    }

    func testTerminalNew() {
        // `working-dir` is always present (the resolved directory); `command` is
        // omitted when nil.
        XCTAssertEqual(
            jsonLine(TerminalNewOut(terminal: "t", workspace: "w", command: nil, workingDir: "/wt")),
            #"{"terminal":"t","working-dir":"/wt","workspace":"w"}"#)
        XCTAssertEqual(
            jsonLine(TerminalNewOut(terminal: "t", workspace: "w", command: "c", workingDir: "/wt")),
            #"{"command":"c","terminal":"t","working-dir":"/wt","workspace":"w"}"#)
    }

    func testTerminalInfoArray() {
        XCTAssertEqual(
            jsonLine([TerminalInfoOut(terminal: "t", workingDir: "d")]),
            #"[{"terminal":"t","working-dir":"d"}]"#)
    }

    func testTerminalClose() {
        XCTAssertEqual(
            jsonLine(TerminalCloseOut(terminal: "t", workspace: "w")),
            #"{"terminal":"t","workspace":"w"}"#)
    }

    func testWorkspaceArray() {
        XCTAssertEqual(
            jsonLine([WorkspaceOut(workspace: "i", name: "n", branch: "b", path: "p")]),
            #"[{"branch":"b","name":"n","path":"p","workspace":"i"}]"#)
        XCTAssertEqual(
            jsonLine([WorkspaceOut(workspace: "i", name: "n", branch: nil, path: "p")]),
            #"[{"name":"n","path":"p","workspace":"i"}]"#)
    }

    func testCurrent() {
        // Full descriptor when the id resolves; each of name/branch/path is
        // omitted when nil, down to the bare `{"workspace"}` fallback.
        XCTAssertEqual(
            jsonLine(CurrentOut(workspace: "i", name: "n", branch: "b", path: "p")),
            #"{"branch":"b","name":"n","path":"p","workspace":"i"}"#)
        XCTAssertEqual(
            jsonLine(CurrentOut(workspace: "i", name: nil, branch: nil, path: "p")),
            #"{"path":"p","workspace":"i"}"#)
        XCTAssertEqual(
            jsonLine(CurrentOut(workspace: "i", name: nil, branch: nil, path: nil)),
            #"{"workspace":"i"}"#)
    }

    func testErrorEscaping() {
        XCTAssertEqual(jsonLine(ErrorOut(error: #"bad "x""#)), #"{"error":"bad \"x\""}"#)
    }
}
