import XCTest
import CasperCore
@testable import CasperCLI

final class ControlCommandTests: XCTestCase {
    func testStatusSetBuildsCommand() throws {
        let set = try StatusCommand.Set.parse(["blocked", "--workspace", "feature"])
        XCTAssertEqual(set.state, .blocked)
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .statusSet)
        XCTAssertEqual(command.state, "blocked")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testStatusSetRejectsBadState() {
        // The typed `AgentState` argument makes ArgumentParser reject an unknown
        // value at parse time (exit 64), before `makeCommand()` ever runs.
        XCTAssertThrowsError(try StatusCommand.Set.parse(["bogus", "--workspace", "feature"]))
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
        let new = try TerminalCommand.New.parse(
            ["--workspace", "feature", "--command", "npm test", "--working-dir", "/some/dir"])
        XCTAssertEqual(new.workingDir, "/some/dir")
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .terminalNew)
        XCTAssertEqual(command.workspace, "feature")
        XCTAssertEqual(command.command, "npm test")
        XCTAssertEqual(command.cwd, "/some/dir")
    }

    func testTerminalNewTreatsEmptyCommandAsNil() throws {
        let new = try TerminalCommand.New.parse(["--workspace", "feature", "--command", ""])
        XCTAssertNil(try new.makeCommand().command)
    }

    func testTerminalListBuildsCommand() throws {
        let list = try TerminalCommand.List.parse(["--workspace", "feature"])
        let command = try list.makeCommand()
        XCTAssertEqual(command.verb, .terminalList)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testTerminalCloseBuildsCommand() throws {
        let uuid = UUID().uuidString
        let close = try TerminalCommand.Close.parse([uuid, "--workspace", "f"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .terminalClose)
        XCTAssertEqual(command.target, uuid)
        XCTAssertEqual(command.workspace, "f")
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

    func testBrowserOpenRejectsInvalidURL() throws {
        let schemeless = try BrowserCommand.Open.parse(["not-a-url", "--workspace", "feature"])
        XCTAssertThrowsError(try schemeless.makeCommand())

        // A dotted host without a scheme parses as a relative URL, not an absolute web URL.
        let dottedHost = try BrowserCommand.Open.parse(["example.com", "--workspace", "feature"])
        XCTAssertThrowsError(try dottedHost.makeCommand())
    }

    func testBrowserCloseBuildsCommand() throws {
        let close = try BrowserCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .browserClose)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testDiffOpenBuildsCommand() throws {
        let open = try DiffCommand.Open.parse(["--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .diffOpen)
        XCTAssertNil(command.target)
    }

    func testDiffOpenCarriesFileArgument() throws {
        let open = try DiffCommand.Open.parse(["Sources/Foo.swift", "--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .diffOpen)
        XCTAssertEqual(command.target, "Sources/Foo.swift")
    }

    func testDiffCloseBuildsCommand() throws {
        let close = try DiffCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .diffClose)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testWorkspaceNewBuildsCommand() throws {
        // The branch is now the required positional subject (not `--branch`).
        let new = try WorkspaceCommand.New.parse(["feature-x", "--base", "main", "--workspace", "primary"])
        XCTAssertEqual(new.branch, "feature-x")
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.branch, "feature-x")
        XCTAssertEqual(command.base, "main")
        XCTAssertNil(command.command)
    }

    func testWorkspaceNewCarriesCommand() throws {
        let new = try WorkspaceCommand.New.parse(["feature-x", "--command", "npm test", "--workspace", "primary"])
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.command, "npm test")
    }

    func testWorkspaceNewTreatsEmptyCommandAsNil() throws {
        let new = try WorkspaceCommand.New.parse(["feature-x", "--command", "", "--workspace", "primary"])
        let command = try new.makeCommand()
        XCTAssertNil(command.command)
    }

    func testWorkspaceNewRequiresBranch() {
        // The branch is a required positional; ArgumentParser rejects its absence at parse time.
        XCTAssertThrowsError(try WorkspaceCommand.New.parse(["--workspace", "primary"]))
    }

    func testWorkspaceDeleteBuildsCommand() throws {
        let delete = try WorkspaceCommand.Delete.parse(["--workspace", "f"])
        let command = try delete.makeCommand()
        XCTAssertEqual(command.verb, .workspaceDelete)
        XCTAssertEqual(command.workspace, "f")
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

    func testNormalizedCommand() {
        // Shared by `terminal new` and `workspace new`: empty string means "no command".
        XCTAssertNil(normalizedCommand(nil))
        XCTAssertNil(normalizedCommand(""))
        XCTAssertEqual(normalizedCommand("npm test"), "npm test")
    }
}
