import XCTest
@testable import CasperCore

final class SocketPathResolutionTests: XCTestCase {
    func testControlResolveNamedSession() {
        let path = ControlSocketPath.resolve(for: SessionIdentity(name: "dev")!)
        XCTAssertTrue(path.hasSuffix("casper-control-dev.sock"), path)
    }

    func testControlResolveDefaultSession() {
        let path = ControlSocketPath.resolve(for: .default)
        XCTAssertTrue(path.hasSuffix("casper-control.sock"), path)
        XCTAssertFalse(path.contains("casper-control-"), path)
    }

    #if DEBUG
    func testDebugResolveNamedSession() {
        XCTAssertEqual(DebugSocketPath.resolve(for: SessionIdentity(name: "dev")!),
                       "/tmp/casper-debug-dev.sock")
    }

    func testDebugResolveDefaultSession() {
        XCTAssertEqual(DebugSocketPath.resolve(for: .default), "/tmp/casper-debug.sock")
    }
    #endif
}
