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
}
