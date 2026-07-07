import Foundation
import XCTest
@testable import CasperCore

final class SocketPathResolutionTests: XCTestCase {
    func testControlResolveNamedSession() {
        // `resolve(for:)` returns CASPER_CONTROL_SOCKET verbatim when set, so the
        // session-derived suffix can only be asserted with a clean env (a terminal
        // opened by a running Casper.app exports CASPER_CONTROL_SOCKET and would
        // otherwise fail this spuriously).
        guard ProcessInfo.processInfo.environment["CASPER_CONTROL_SOCKET"] == nil else { return }
        let path = ControlSocketPath.resolve(for: SessionIdentity(name: "dev")!)
        XCTAssertTrue(path.hasSuffix("casper-control-dev.sock"), path)
    }

    func testControlResolveDefaultSession() {
        // See testControlResolveNamedSession: a set CASPER_CONTROL_SOCKET overrides
        // the derived path, so assert the clean-env contract only when it is unset.
        guard ProcessInfo.processInfo.environment["CASPER_CONTROL_SOCKET"] == nil else { return }
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
