import XCTest
import CasperCore
@testable import CasperCLI

final class ControlCommandTests: XCTestCase {
    func testStatusSetBuildsCommand() throws {
        var set = StatusCommand.Set()
        set.state = "waiting"
        set.target.workspace = "feature"
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .statusSet)
        XCTAssertEqual(command.state, "waiting")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testStatusSetRejectsBadState() {
        var set = StatusCommand.Set()
        set.state = "bogus"
        set.target.workspace = "feature"
        XCTAssertThrowsError(try set.makeCommand())
    }

    func testProgressSetBuildsCommand() throws {
        var set = ProgressCommand.Set()
        set.total = 5; set.current = 3; set.label = "wire"
        set.target.workspace = "feature"
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .progressSet)
        XCTAssertEqual(command.total, 5)
        XCTAssertEqual(command.current, 3)
        XCTAssertEqual(command.label, "wire")
    }

    func testProgressSetRejectsOutOfRange() {
        var set = ProgressCommand.Set()
        set.total = 2; set.current = 5; set.label = "x"
        set.target.workspace = "feature"
        XCTAssertThrowsError(try set.makeCommand())
    }

    func testProgressClearBuildsCommand() throws {
        var clear = ProgressCommand.Clear()
        clear.target.workspace = "feature"
        let command = try clear.makeCommand()
        XCTAssertEqual(command.verb, .progressClear)
    }

    func testNotifyBuildsCommand() throws {
        var notify = NotifyCommand()
        notify.message = "look here"
        notify.target.workspace = "feature"
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertEqual(command.message, "look here")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testNotifyWithoutMessage() throws {
        var notify = NotifyCommand()
        notify.target.workspace = "feature"
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertNil(command.message)
    }

    func testTerminalNewBuildsCommand() throws {
        var new = TerminalCommand.New()
        new.target.workspace = "feature"
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .terminalNew)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testBrowserOpenBuildsCommand() throws {
        var open = BrowserCommand.Open()
        open.url = "https://example.com"
        open.target.workspace = "feature"
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .browserOpen)
        XCTAssertEqual(command.url, "https://example.com")
    }

    func testBrowserOpenRejectsEmptyURL() {
        var open = BrowserCommand.Open()
        open.url = ""
        open.target.workspace = "feature"
        XCTAssertThrowsError(try open.makeCommand())
    }

    func testDiffShowBuildsCommand() throws {
        var show = DiffCommand.Show()
        show.workspaceTarget.workspace = "feature"
        let command = try show.makeCommand()
        XCTAssertEqual(command.verb, .diffShow)
    }

    func testWorkspaceNewBuildsCommand() throws {
        var new = WorkspaceCommand.New()
        new.branch = "feature-x"
        new.base = "main"
        new.target.workspace = "primary"
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.branch, "feature-x")
        XCTAssertEqual(command.base, "main")
    }

    func testWorkspaceNewRequiresBranch() {
        var new = WorkspaceCommand.New()
        new.branch = ""
        new.target.workspace = "primary"
        XCTAssertThrowsError(try new.makeCommand())
    }

    func testWorkspaceListBuildsCommand() throws {
        let list = WorkspaceCommand.List()
        XCTAssertEqual(list.makeCommand().verb, .workspaceList)
    }

    func testWorkspaceCurrentReadsEnv() throws {
        let current = WorkspaceCommand.Current()
        XCTAssertEqual(current.resolve(environment: ["CASPER_WORKSPACE_ID": "abc"]), "abc")
        XCTAssertNil(current.resolve(environment: [:]))
    }
}
