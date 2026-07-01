import XCTest
import CasperCLI

final class HooksRoutingTests: XCTestCase {
    func testHooksFeedRoutesToFeed() throws {
        let command = try CasperCommand.parseAsRoot(["hooks", "feed"])
        XCTAssertTrue(command is HooksFeedCommand)
    }

    func testHooksSetupRoutesToSetup() throws {
        let command = try CasperCommand.parseAsRoot(["hooks", "setup", "/tmp/x"])
        XCTAssertTrue(command is HooksSetupCommand)
    }
}
