#if DEBUG
import Foundation
import XCTest
@testable import CasperCore

final class DebugProtocolTests: XCTestCase {
    /// An 80×24 grid on a 2× display.
    private let retinaGeometry = DebugState.Geometry(
        columns: 80, rows: 24,
        widthPixels: 1600, heightPixels: 960, cellWidthPixels: 20, cellHeightPixels: 40,
        boundsWidth: 800, boundsHeight: 480, backingWidth: 1600, backingHeight: 960,
        contentScaleX: 2, contentScaleY: 2, backingScaleFactor: 2)

    /// `DebugCommand` is a flat struct with a fully synthesized `Codable`, so a
    /// single round trip over a fixture that populates *every* field covers all
    /// verbs. `Equatable` compares every field, so the one assertion pins them all
    /// — a newly added field is only covered once it is set here too.
    func testCommandRoundTripsEveryField() throws {
        let command = DebugCommand(
            verb: .sendText, text: "ls", enter: true, mods: ["control", "shift"],
            scrollback: true, path: "/tmp/shot.png", target: "0", x: 12.5, y: 34.75)
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(DebugCommand.self, from: data), command)
    }

    func testResponseWithStateRoundTrip() throws {
        let state = DebugState(surfaces: [
            .init(
                id: "0", title: "casper", workingDirectory: "/tmp", focused: true,
                geometry: retinaGeometry),
        ])
        let response = DebugResponse.success(state: state)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DebugResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.state?.surfaces.first?.geometry.columns, 80)
    }

    func testResponseWithMemoryRoundTrip() throws {
        let memory = DebugMemory(
            footprintBytes: 120_000_000, residentBytes: 90_000_000, peakFootprintBytes: 130_000_000,
            liveObjects: [.init(label: "GhosttySurfaceView", live: 2, created: 7)],
            counters: ["surfaceViews": 2, "nsWindows": 1])
        let response = DebugResponse.success(memory: memory)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DebugResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.memory?.liveObjects.first?.live, 2)
        XCTAssertEqual(decoded.memory?.counters["surfaceViews"], 2)
    }

    func testSurfaceRoundTripCarriesAgentDetectionFields() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: "/tmp", focused: true, geometry: retinaGeometry,
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
            id: "0", title: "casper", workingDirectory: "/tmp", focused: true, geometry: retinaGeometry)
        let data = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(DebugState.Surface.self, from: data)
        XCTAssertEqual(decoded, surface)
        XCTAssertNil(decoded.agentState)
        XCTAssertNil(decoded.oscTitle)
        XCTAssertNil(decoded.progressReport)
    }

    /// `dump-state` prints a surface as flat JSON, and the `debug-casper` skill reads
    /// those keys (`cellWidthPixels` and the like) by name: the key set is a contract.
    func testSurfaceEncodesTheFlatDumpStateKeys() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: "/tmp", focused: true, geometry: retinaGeometry,
            agentState: "working", oscTitle: "casper", progressReport: "indeterminate")
        XCTAssertEqual(try encodedKeys(of: surface), [
            "agentState", "backingHeight", "backingScaleFactor", "backingWidth", "boundsHeight",
            "boundsWidth", "cellHeightPixels", "cellWidthPixels", "columns", "contentScaleX",
            "contentScaleY", "focused", "heightPixels", "id", "oscTitle", "progressReport", "rows",
            "title", "widthPixels", "workingDirectory",
        ])
    }

    /// The optional fields are omitted when nil, not encoded as `null`.
    func testSurfaceOmitsNilOptionalKeys() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: nil, focused: false, geometry: retinaGeometry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(surface), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"backingHeight":960,"backingScaleFactor":2,"backingWidth":1600,"boundsHeight":480,"#
                + #""boundsWidth":800,"cellHeightPixels":40,"cellWidthPixels":20,"columns":80,"#
                + #""contentScaleX":2,"contentScaleY":2,"focused":false,"heightPixels":960,"id":"0","#
                + #""rows":24,"title":"casper","widthPixels":1600}"#)
    }

    private func encodedKeys(of surface: DebugState.Surface) throws -> [String] {
        let data = try JSONEncoder().encode(surface)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object.keys.sorted()
    }

    func testFailureHelper() {
        let response = DebugResponse.failure("no surface")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no surface")
    }
}
#endif
