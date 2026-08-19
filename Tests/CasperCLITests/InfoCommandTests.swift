import XCTest
import CasperCore
@testable import CasperCLI

final class InfoCommandTests: XCTestCase {
    func testSetBuildsCommandFromMessage() throws {
        let set = try InfoCommand.Set.parse(["--message", "## Ready", "--workspace", "feature"])
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .infoSet)
        XCTAssertEqual(command.message, "## Ready")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testSetReadsMarkdownFromFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("info-\(UUID().uuidString).md")
        try "## Ready\n- <http://localhost:8080>\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let set = try InfoCommand.Set.parse(["--file", url.path, "--workspace", "feature"])
        XCTAssertEqual(try set.resolveMarkdown(), "## Ready\n- <http://localhost:8080>\n")
    }

    func testSetReadsMarkdownFromStdinWhenNotATTY() throws {
        let set = try InfoCommand.Set.parse(["--workspace", "feature"])
        let markdown = try set.resolveMarkdown(
            readStdin: { "## Ready\n" }, isStandardInputATTY: { false })
        XCTAssertEqual(markdown, "## Ready\n")
    }

    func testSetRejectsBareInvocationOnAnInteractiveTerminal() throws {
        let set = try InfoCommand.Set.parse(["--workspace", "feature"])
        XCTAssertThrowsError(
            try set.resolveMarkdown(readStdin: { "## Ready\n" }, isStandardInputATTY: { true }))
    }

    func testSetAcceptsDashAsExplicitStdinMarker() throws {
        let set = try InfoCommand.Set.parse(["-", "--workspace", "feature"])
        XCTAssertEqual(try set.resolveMarkdown(readStdin: { "## Ready\n" }), "## Ready\n")
    }

    func testSetAcceptsDashEvenOnAnInteractiveTerminal() throws {
        // An explicit '-' is the caller saying they mean it: it reads stdin
        // unconditionally, unlike the bare-invocation fallback above.
        let set = try InfoCommand.Set.parse(["-", "--workspace", "feature"])
        let markdown = try set.resolveMarkdown(
            readStdin: { "## Ready\n" }, isStandardInputATTY: { true })
        XCTAssertEqual(markdown, "## Ready\n")
    }

    func testSetRejectsAnyOtherPositionalArgument() throws {
        let set = try InfoCommand.Set.parse(["notes.md", "--workspace", "feature"])
        // Non-empty, well-formed stdin: if the `source != "-"` guard were ever
        // deleted, `resolveMarkdown` would fall through to reading this stdin and
        // succeed, since nothing else here would reject it — unlike the blank-
        // message guard, which would mask the deletion by throwing anyway for an
        // unrelated reason if stdin were left empty.
        XCTAssertThrowsError(
            try set.resolveMarkdown(readStdin: { "## Ready" }, isStandardInputATTY: { false }))
    }

    func testSetRejectsMessageAndFileTogether() throws {
        let set = try InfoCommand.Set.parse(
            ["--message", "x", "--file", "/tmp/x.md", "--workspace", "feature"])
        XCTAssertThrowsError(try set.resolveMarkdown(readStdin: { "" }))
    }

    func testSetRejectsUnreadableFile() throws {
        let set = try InfoCommand.Set.parse(
            ["--file", "/nonexistent/\(UUID().uuidString).md", "--workspace", "feature"])
        XCTAssertThrowsError(try set.resolveMarkdown(readStdin: { "" }))
    }

    func testSetRejectsBlankMessage() throws {
        let set = try InfoCommand.Set.parse(["--message", "   \n ", "--workspace", "feature"])
        XCTAssertThrowsError(try set.resolveMarkdown(readStdin: { "" }))
    }

    func testSetRejectsOversizedMessage() throws {
        let set = try InfoCommand.Set.parse(["--workspace", "feature"])
        let oversized = String(repeating: "a", count: ControlCommand.infoMessageMaxBytes + 1)
        XCTAssertThrowsError(
            try set.resolveMarkdown(readStdin: { oversized }, isStandardInputATTY: { false }))
    }

    func testClearBuildsCommand() throws {
        let clear = try InfoCommand.Clear.parse(["--workspace", "feature"])
        let command = try clear.makeCommand()
        XCTAssertEqual(command.verb, .infoClear)
        XCTAssertEqual(command.workspace, "feature")
        XCTAssertNil(command.message)
    }
}
