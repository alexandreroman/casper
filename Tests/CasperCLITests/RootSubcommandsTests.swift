import XCTest
@testable import CasperCLI

final class RootSubcommandsTests: XCTestCase {
    func testDomainCommandsAreRegistered() {
        let names = CasperCommand.configuration.subcommands.map { $0.configuration.commandName }
        for expected in ["status", "progress", "notify", "terminal", "browser", "diff", "workspace"] {
            XCTAssertTrue(names.contains(expected), "missing subcommand: \(expected)")
        }
    }
}
