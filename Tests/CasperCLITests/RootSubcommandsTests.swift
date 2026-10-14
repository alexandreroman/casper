import XCTest
@testable import CasperCLI

final class RootSubcommandsTests: XCTestCase {
    func testRootRegistersExactlyTheDomainCommands() {
        var expected = [
            "status", "progress", "notify", "info", "terminal", "browser", "diff", "workspace", "run",
        ]
        #if DEBUG
        expected.append("debug")
        #endif
        let names = CasperCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(names, expected)
    }
}
