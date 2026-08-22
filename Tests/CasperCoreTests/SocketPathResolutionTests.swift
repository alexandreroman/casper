import Foundation
import XCTest
@testable import CasperCore

final class SocketPathResolutionTests: XCTestCase {
    func testControlListenPathIgnoresEnvOverride() {
        // The root cause: the App must bind its listener to the session-derived
        // path even when it inherited a CASPER_CONTROL_SOCKET from a terminal a
        // *different* running instance opened. This asserts the override is
        // ignored, so `controlSocketPath()` never reads the env var.
        withEnvironmentVariable("CASPER_CONTROL_SOCKET", setTo: "/tmp/should-not-be-used.sock") {
            let path = SessionIdentity(name: "dev")!.controlSocketPath()
            XCTAssertTrue(path.hasSuffix("casper-control-dev.sock"), path)
        }
    }

    #if DEBUG
    func testDebugResolveNamedSession() throws {
        try skipWhenDebugSocketIsOverridden()
        XCTAssertEqual(DebugSocketPath.resolve(for: SessionIdentity(name: "dev")!),
                       "/tmp/casper-debug-dev.sock")
    }

    func testDebugResolveDefaultSession() throws {
        try skipWhenDebugSocketIsOverridden()
        XCTAssertEqual(DebugSocketPath.resolve(for: .default), "/tmp/casper-debug.sock")
    }

    func testDebugListenPathIgnoresEnvOverride() {
        withEnvironmentVariable("CASPER_DEBUG_SOCKET", setTo: "/tmp/should-not-be-used.sock") {
            XCTAssertEqual(DebugSocketPath.listenPath(for: SessionIdentity(name: "dev")!),
                           "/tmp/casper-debug-dev.sock")
        }
    }

    /// `resolve(for:)` is the dial side, where an ambient `CASPER_DEBUG_SOCKET` is meant to
    /// win over the session-derived path — and every terminal a running Casper opens exports
    /// one. `make test` strips it; a bare `swift test` from such a terminal does not, and
    /// there is no session-derived path to assert against then.
    private func skipWhenDebugSocketIsOverridden() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASPER_DEBUG_SOCKET"] == nil,
            "an ambient CASPER_DEBUG_SOCKET overrides the dial-side path — run via `make test`")
    }
    #endif

    /// Run `body` with `name` set to `value`, then put back exactly what the process had.
    /// Plain `unsetenv` would instead *delete* an ambient `CASPER_*_SOCKET` for the rest of
    /// the test process — and that variable is precisely what a terminal opened by a running
    /// Casper exports, which the dial-side resolution tests here read.
    private func withEnvironmentVariable(_ name: String, setTo value: String, _ body: () -> Void) {
        let inherited = getenv(name).map { String(cString: $0) }
        setenv(name, value, 1)
        defer {
            if let inherited {
                setenv(name, inherited, 1)
            } else {
                unsetenv(name)
            }
        }
        body()
    }
}
