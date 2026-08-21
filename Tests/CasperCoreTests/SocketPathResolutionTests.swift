import XCTest
@testable import CasperCore

final class SocketPathResolutionTests: XCTestCase {
    func testControlListenPathUsesSessionDerivedPath() {
        let path = SessionIdentity(name: "dev")!.controlSocketPath()
        XCTAssertTrue(path.hasSuffix("casper-control-dev.sock"), path)
    }

    func testControlListenPathIgnoresEnvOverride() {
        // The root cause: the App must bind its listener to the session-derived
        // path even when it inherited a CASPER_CONTROL_SOCKET from a terminal a
        // *different* running instance opened. This asserts the override is
        // ignored, so `controlSocketPath()` never reads the env var.
        setenv("CASPER_CONTROL_SOCKET", "/tmp/should-not-be-used.sock", 1)
        defer { unsetenv("CASPER_CONTROL_SOCKET") }
        let path = SessionIdentity(name: "dev")!.controlSocketPath()
        XCTAssertTrue(path.hasSuffix("casper-control-dev.sock"), path)
    }

    #if DEBUG
    func testDebugResolveNamedSession() {
        XCTAssertEqual(DebugSocketPath.resolve(for: SessionIdentity(name: "dev")!),
                       "/tmp/casper-debug-dev.sock")
    }

    func testDebugResolveDefaultSession() {
        XCTAssertEqual(DebugSocketPath.resolve(for: .default), "/tmp/casper-debug.sock")
    }

    func testDebugListenPathUsesSessionDerivedPath() {
        XCTAssertEqual(DebugSocketPath.listenPath(for: SessionIdentity(name: "dev")!),
                       "/tmp/casper-debug-dev.sock")
    }

    func testDebugListenPathIgnoresEnvOverride() {
        setenv("CASPER_DEBUG_SOCKET", "/tmp/should-not-be-used.sock", 1)
        defer { unsetenv("CASPER_DEBUG_SOCKET") }
        XCTAssertEqual(DebugSocketPath.listenPath(for: SessionIdentity(name: "dev")!),
                       "/tmp/casper-debug-dev.sock")
    }
    #endif
}
