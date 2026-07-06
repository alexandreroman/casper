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

    func testProgressNull() {
        XCTAssertEqual(
            jsonLine(ProgressOut(progress: nil, workspace: "W")),
            #"{"progress":null,"workspace":"W"}"#)
    }

    func testNotify() {
        XCTAssertEqual(
            jsonLine(NotifyOut(pendingNotification: false, workspace: "W")),
            #"{"pendingNotification":false,"workspace":"W"}"#)
    }

    func testTerminal() {
        XCTAssertEqual(
            jsonLine(TerminalOut(terminal: Opened(opened: true), workspace: "W")),
            #"{"terminal":{"opened":true},"workspace":"W"}"#)
    }

    func testBrowserSlashesNotEscaped() {
        XCTAssertEqual(
            jsonLine(BrowserOut(browser: BrowserBody(url: "https://example.com/a"), workspace: "W")),
            #"{"browser":{"url":"https://example.com/a"},"workspace":"W"}"#)
    }

    func testDiff() {
        XCTAssertEqual(
            jsonLine(DiffOut(view: "diff", workspace: "W")),
            #"{"view":"diff","workspace":"W"}"#)
    }

    func testWorkspaceNew() {
        XCTAssertEqual(
            jsonLine(WorkspaceNewOut(workspace: "i", name: "n", branch: "b")),
            #"{"branch":"b","name":"n","workspace":"i"}"#)
    }

    func testCurrent() {
        XCTAssertEqual(jsonLine(CurrentOut(workspace: "i")), #"{"workspace":"i"}"#)
    }

    func testWorkspaceArray() {
        XCTAssertEqual(
            jsonLine([WorkspaceOut(id: "i", name: "n", branch: "b")]),
            #"[{"branch":"b","id":"i","name":"n"}]"#)
    }

    func testErrorEscaping() {
        XCTAssertEqual(jsonLine(ErrorOut(error: #"bad "x""#)), #"{"error":"bad \"x\""}"#)
    }
}
