import XCTest
@testable import CasperCore

final class ProgressSynthesisTests: XCTestCase {
    func testMidwayProgress() throws {
        let todos = try XCTUnwrap(ProgressSynthesis.todos(total: 5, current: 3, label: "wire"))
        XCTAssertEqual(todos.count, 5)
        XCTAssertEqual(todos.filter { $0.status == .completed }.count, 2)
        XCTAssertEqual(todos.filter { $0.status == .pending }.count, 2)
        let inProgress = todos.filter { $0.status == .inProgress }
        XCTAssertEqual(inProgress.count, 1)
        XCTAssertEqual(inProgress.first?.content, "wire")
    }

    func testFirstAndLast() throws {
        let first = try XCTUnwrap(ProgressSynthesis.todos(total: 3, current: 1, label: "a"))
        XCTAssertEqual(first.filter { $0.status == .completed }.count, 0)
        let last = try XCTUnwrap(ProgressSynthesis.todos(total: 3, current: 3, label: "z"))
        XCTAssertEqual(last.filter { $0.status == .completed }.count, 2)
        XCTAssertTrue(last.last?.status == .inProgress)
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(ProgressSynthesis.todos(total: 0, current: 1, label: "x"))
        XCTAssertNil(ProgressSynthesis.todos(total: 3, current: 0, label: "x"))
        XCTAssertNil(ProgressSynthesis.todos(total: 3, current: 4, label: "x"))
    }

    func testTotalIsBoundedSoUntrustedInputCannotExhaustMemory() throws {
        let ceiling = ProgressSynthesis.maxSynthesizedTotal
        let atCeiling = try XCTUnwrap(ProgressSynthesis.todos(total: ceiling, current: 1, label: "x"))
        XCTAssertEqual(atCeiling.count, ceiling)
        XCTAssertNil(ProgressSynthesis.todos(total: ceiling + 1, current: 1, label: "x"))
        XCTAssertNil(ProgressSynthesis.todos(total: .max, current: 1, label: "x"))
    }
}
