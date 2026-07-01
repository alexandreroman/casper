import Foundation
import Network
import XCTest
@testable import CasperAgents

final class HookSocketTests: XCTestCase {
    /// A unique, short socket path under the temp dir (AF_UNIX paths are length
    /// limited, so avoid the long default temporaryDirectory when possible).
    private func tempSocketPath() -> String {
        "/tmp/casper-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testServerStartsAndStopsCleanly() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path)
        try server.start()
        server.stop()
        // A fresh server can rebind the same path after stop().
        let server2 = HookSocketServer(socketPath: path)
        try server2.start()
        server2.stop()
    }
}
