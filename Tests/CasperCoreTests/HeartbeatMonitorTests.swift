import Foundation
import XCTest
@testable import CasperCore

final class HeartbeatMonitorTests: XCTestCase {
    func testWorkspacesPastTimeoutAreStale() {
        let old = UUID(), fresh = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let lastSeen = [
            old: Date(timeIntervalSince1970: 900),   // 100s ago
            fresh: Date(timeIntervalSince1970: 990),  // 10s ago
        ]
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: lastSeen, now: now, timeout: 30)
        XCTAssertEqual(stale, [old])
    }

    func testExactlyAtTimeoutIsNotStale() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: [id: Date(timeIntervalSince1970: 970)], now: now, timeout: 30)
        XCTAssertTrue(stale.isEmpty)
    }

    func testEmptyInputYieldsNoStale() {
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: [:], now: Date(), timeout: 30)
        XCTAssertTrue(stale.isEmpty)
    }
}
