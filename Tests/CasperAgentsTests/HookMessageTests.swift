import Foundation
import XCTest
@testable import CasperAgents

final class HookMessageTests: XCTestCase {
    func testJSONRoundTripPreservesFields() throws {
        let payload = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = HookMessage(workspaceId: UUID(), hookPayload: payload)
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(HookMessage.self, from: encoded)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.hookPayload, payload)
    }
}
