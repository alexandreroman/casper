#if DEBUG
import Foundation
import XCTest
@testable import CasperCore

final class DebugProtocolTests: XCTestCase {
    func testCommandRoundTrip() throws {
        let command = DebugCommand(verb: .sendText, text: "ls", enter: true)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testResponseWithStateRoundTrip() throws {
        let state = DebugState(surfaces: [
            .init(
                id: "0", title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true,
                widthPixels: 1600, heightPixels: 960, cellWidthPixels: 20, cellHeightPixels: 40,
                boundsWidth: 800, boundsHeight: 480, backingWidth: 1600, backingHeight: 960,
                contentScaleX: 2, contentScaleY: 2, backingScaleFactor: 2),
        ])
        let response = DebugResponse.success(state: state)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DebugResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.state?.surfaces.first?.columns, 80)
    }

    func testSurfaceRoundTripCarriesAgentDetectionFields() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true,
            widthPixels: 1600, heightPixels: 960, cellWidthPixels: 20, cellHeightPixels: 40,
            boundsWidth: 800, boundsHeight: 480, backingWidth: 1600, backingHeight: 960,
            contentScaleX: 2, contentScaleY: 2, backingScaleFactor: 2,
            agentState: "working", oscTitle: "\u{2807} casper", progressReport: "indeterminate")
        let data = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(DebugState.Surface.self, from: data)
        XCTAssertEqual(decoded, surface)
        XCTAssertEqual(decoded.agentState, "working")
        XCTAssertEqual(decoded.oscTitle, "\u{2807} casper")
        XCTAssertEqual(decoded.progressReport, "indeterminate")
    }

    /// The three detection fields default to nil, so a surface built without them — and a payload
    /// encoded before they existed — still decodes.
    func testSurfaceRoundTripWithoutAgentDetectionFields() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true,
            widthPixels: 1600, heightPixels: 960, cellWidthPixels: 20, cellHeightPixels: 40,
            boundsWidth: 800, boundsHeight: 480, backingWidth: 1600, backingHeight: 960,
            contentScaleX: 2, contentScaleY: 2, backingScaleFactor: 2)
        let data = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(DebugState.Surface.self, from: data)
        XCTAssertEqual(decoded, surface)
        XCTAssertNil(decoded.agentState)
        XCTAssertNil(decoded.oscTitle)
        XCTAssertNil(decoded.progressReport)
    }

    func testFailureHelper() {
        let response = DebugResponse.failure("no surface")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no surface")
    }

    func testCommandRoundTripWithTargetAndFocusVerb() throws {
        let command = DebugCommand(verb: .focus, target: "0")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.verb, .focus)
        XCTAssertEqual(decoded.target, "0")
    }

    func testCommandRoundTripWithMouseMoveVerb() throws {
        let command = DebugCommand(verb: .mouseMove, target: "0", x: 12.5, y: 34.75)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.verb, .mouseMove)
        XCTAssertEqual(decoded.x, 12.5)
        XCTAssertEqual(decoded.y, 34.75)
    }
}
#endif
