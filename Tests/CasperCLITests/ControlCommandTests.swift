import XCTest
import CasperCore
@testable import CasperCLI

final class ControlCommandTests: XCTestCase {
    func testStatusSetBuildsCommand() throws {
        let set = try StatusCommand.Set.parse(["waiting", "--workspace", "feature"])
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .statusSet)
        XCTAssertEqual(command.state, "waiting")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testStatusSetRejectsBadState() throws {
        let set = try StatusCommand.Set.parse(["bogus", "--workspace", "feature"])
        XCTAssertThrowsError(try set.makeCommand())
    }

    func testProgressSetBuildsCommand() throws {
        let set = try ProgressCommand.Set.parse(
            ["--total", "5", "--current", "3", "--label", "wire", "--workspace", "feature"])
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .progressSet)
        XCTAssertEqual(command.total, 5)
        XCTAssertEqual(command.current, 3)
        XCTAssertEqual(command.label, "wire")
    }

    func testProgressSetRejectsOutOfRange() throws {
        let set = try ProgressCommand.Set.parse(
            ["--total", "2", "--current", "5", "--label", "x", "--workspace", "feature"])
        XCTAssertThrowsError(try set.makeCommand())
    }

    func testProgressClearBuildsCommand() throws {
        let clear = try ProgressCommand.Clear.parse(["--workspace", "feature"])
        let command = try clear.makeCommand()
        XCTAssertEqual(command.verb, .progressClear)
    }

    func testNotifyBuildsCommand() throws {
        let notify = try NotifyCommand.parse(["--message", "look here", "--workspace", "feature"])
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertEqual(command.message, "look here")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testNotifyWithoutMessage() throws {
        let notify = try NotifyCommand.parse(["--workspace", "feature"])
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertNil(command.message)
    }

    func testTerminalNewBuildsCommand() throws {
        let new = try TerminalCommand.New.parse(["--workspace", "feature"])
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .terminalNew)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testBrowserOpenBuildsCommand() throws {
        let open = try BrowserCommand.Open.parse(["https://example.com", "--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .browserOpen)
        XCTAssertEqual(command.url, "https://example.com")
    }

    func testBrowserOpenRejectsEmptyURL() throws {
        let open = try BrowserCommand.Open.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try open.makeCommand())
    }

    func testDiffShowBuildsCommand() throws {
        let show = try DiffCommand.Show.parse(["--workspace", "feature"])
        let command = try show.makeCommand()
        XCTAssertEqual(command.verb, .diffShow)
    }

    func testWorkspaceNewBuildsCommand() throws {
        let new = try WorkspaceCommand.New.parse(
            ["--branch", "feature-x", "--base", "main", "--workspace", "primary"])
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.branch, "feature-x")
        XCTAssertEqual(command.base, "main")
    }

    func testWorkspaceNewRequiresBranch() throws {
        let new = try WorkspaceCommand.New.parse(["--workspace", "primary"])
        XCTAssertThrowsError(try new.makeCommand())
    }

    func testWorkspaceListBuildsCommand() throws {
        let list = try WorkspaceCommand.List.parse([])
        XCTAssertEqual(list.makeCommand().verb, .workspaceList)
    }

    func testWorkspaceCurrentReadsEnv() throws {
        let current = try WorkspaceCommand.Current.parse([])
        XCTAssertEqual(current.resolve(environment: ["CASPER_WORKSPACE_ID": "abc"]), "abc")
        XCTAssertNil(current.resolve(environment: [:]))
    }
}
