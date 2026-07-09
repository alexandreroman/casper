import GhosttyKit
import XCTest
@testable import CasperGhostty

final class GhosttySurfaceConfigurationTests: XCTestCase {
    func testMarshalsDirectoryAndEnv() {
        var config = GhosttySurfaceConfiguration()
        config.workingDirectory = "/tmp/wt"
        config.environment = ["CASPER_PORT": "40000"]
        config.scaleFactor = 2.0

        // A throwaway non-null pointer stands in for the NSView.
        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            let nsview = UnsafeMutableRawPointer(raw)
            config.withCValue(nsview: nsview, userdata: nil) { c in
                XCTAssertEqual(c.platform_tag, GHOSTTY_PLATFORM_MACOS)
                XCTAssertEqual(c.platform.macos.nsview, nsview)
                XCTAssertEqual(c.scale_factor, 2.0)
                XCTAssertEqual(String(cString: c.working_directory), "/tmp/wt")
                XCTAssertEqual(c.env_var_count, 1)
                XCTAssertEqual(String(cString: c.env_vars.pointee.key), "CASPER_PORT")
                XCTAssertEqual(String(cString: c.env_vars.pointee.value), "40000")
            }
        }
    }

    func testNilDirectoryLeavesNullPointer() {
        let config = GhosttySurfaceConfiguration()
        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            config.withCValue(nsview: UnsafeMutableRawPointer(raw), userdata: nil) { c in
                XCTAssertNil(c.working_directory)
                XCTAssertEqual(c.env_var_count, 0)
            }
        }
    }

    func testMarshalsInitialInput() {
        var config = GhosttySurfaceConfiguration()
        config.initialInput = "echo hi\n"

        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            let nsview = UnsafeMutableRawPointer(raw)
            config.withCValue(nsview: nsview, userdata: nil) { c in
                XCTAssertEqual(String(cString: c.initial_input), "echo hi\n")
            }
        }
    }

    func testNilInitialInputLeavesNullPointer() {
        let config = GhosttySurfaceConfiguration()
        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            config.withCValue(nsview: UnsafeMutableRawPointer(raw), userdata: nil) { c in
                XCTAssertNil(c.initial_input)
            }
        }
    }
}
