import XCTest
@testable import CasperCLI

final class RootSubcommandsTests: XCTestCase {
    func testDomainCommandsAreRegistered() {
        let names = CasperCommand.configuration.subcommands.map { $0.configuration.commandName }
        for expected in ["status", "progress", "notify", "terminal", "browser", "diff", "workspace", "run"] {
            XCTAssertTrue(names.contains(expected), "missing subcommand: \(expected)")
        }
    }

    func testHooksDomainIsRemoved() {
        let names = CasperCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertFalse(names.contains("hooks"))
    }
}
