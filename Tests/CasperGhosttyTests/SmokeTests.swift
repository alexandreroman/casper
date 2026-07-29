import GhosttyKit
import XCTest
@testable import CasperGhostty

final class SmokeTests: XCTestCase {
    /// Calls the real `ghostty_info` symbol from the linked GhosttyKit binary, so
    /// this test fails to *link* (not just assert) if the xcframework or headers
    /// are wrong. `ghostty_info` is safe to call with no prior `ghostty_init` and
    /// no app/surface/GUI setup: it is a pure, zero-argument query for build
    /// metadata.
    func testGhosttyInfoLinksAndReportsAKnownBuild() throws {
        let info = ghostty_info()

        let knownBuildModes: [ghostty_build_mode_e] = [
            GHOSTTY_BUILD_MODE_DEBUG,
            GHOSTTY_BUILD_MODE_RELEASE_SAFE,
            GHOSTTY_BUILD_MODE_RELEASE_FAST,
            GHOSTTY_BUILD_MODE_RELEASE_SMALL,
        ]
        XCTAssertTrue(knownBuildModes.contains(info.build_mode))

        XCTAssertGreaterThan(info.version_len, 0)
        let versionLength = Int(info.version_len)
        let versionPointer = try XCTUnwrap(info.version)
        let version = versionPointer.withMemoryRebound(to: UInt8.self, capacity: versionLength) {
            String(decoding: UnsafeBufferPointer(start: $0, count: versionLength), as: UTF8.self)
        }
        XCTAssertFalse(version.isEmpty)
    }
}
