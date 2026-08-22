#if DEBUG
import AppKit
import XCTest
@testable import CasperGhostty

/// Covers the id matching shared by the `--target` resolution and the `focus`
/// verb, both of which funnel through `DebugServer.surface(withID:in:)`.
@MainActor
final class DebugServerTargetTests: XCTestCase {
    // Letter-bearing, with both cases spelled out as literals: a digit-only id
    // would make the case assertions pass against a case-sensitive match too.
    private let canonicalID = "abcdef01-abcd-4bcd-8bcd-abcdef012345"
    private let uppercasedID = "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345"

    func testResolvesTheCanonicalLowercaseID() {
        let surfaces = [makeHandle(id: canonicalID)]
        XCTAssertEqual(DebugServer.surface(withID: canonicalID, in: surfaces)?.id, canonicalID)
    }

    func testResolvesAnUppercaseID() {
        let surfaces = [makeHandle(id: canonicalID)]
        XCTAssertEqual(DebugServer.surface(withID: uppercasedID, in: surfaces)?.id, canonicalID)
    }

    func testDoesNotResolveAnUnknownID() {
        let surfaces = [makeHandle(id: canonicalID)]
        XCTAssertNil(DebugServer.surface(withID: "fedcba98-fedc-4fed-8fed-fedcba987654", in: surfaces))
    }

    private func makeHandle(id: String) -> DebugSurfaceHandle {
        DebugSurfaceHandle(
            id: id, title: "", workingDirectory: nil, focused: false,
            readText: { _ in nil },
            sendText: { _, _ in },
            sendKeys: { _ in },
            sendKey: { _, _ in },
            sendAction: { _ in },
            mouseMove: { _, _ in },
            geometry: { .zero },
            focus: {},
            window: nil)
    }
}
#endif
