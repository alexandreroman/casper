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

    /// Read-back is the exact inverse of synthesis for a list this type built,
    /// which is what makes `progress get` echo back what `progress set` reported.
    func testReportRoundTripsASynthesizedList() throws {
        for (total, current) in [(5, 3), (1, 1), (3, 1), (3, 3)] {
            let todos = try XCTUnwrap(
                ProgressSynthesis.todos(total: total, current: current, label: "step"))
            let report = try XCTUnwrap(ProgressSynthesis.report(from: todos))
            XCTAssertEqual(report.total, total)
            XCTAssertEqual(report.current, current)
            XCTAssertEqual(report.label, "step")
        }
    }

    /// An empty list is the one "no bar on screen" state, and the only nil.
    func testReportOfAnEmptyListIsNil() {
        XCTAssertNil(ProgressSynthesis.report(from: []))
    }

    /// A list from a real todo tool: the live step is the first one not yet
    /// completed, whatever its status, and an all-completed list reports its last.
    func testReportSummarizesAToolAuthoredList() throws {
        let list = [
            Todo(content: "read", status: .completed),
            Todo(content: "write", status: .inProgress),
            Todo(content: "test", status: .pending),
        ]
        let report = try XCTUnwrap(ProgressSynthesis.report(from: list))
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.current, 2)
        XCTAssertEqual(report.label, "write")

        let finished = try XCTUnwrap(ProgressSynthesis.report(
            from: list.map { Todo(content: $0.content, status: .completed) }))
        XCTAssertEqual(finished.current, 3)
        XCTAssertEqual(finished.label, "test")
    }

    func testTotalIsBoundedSoUntrustedInputCannotExhaustMemory() throws {
        let ceiling = ProgressSynthesis.maxSynthesizedTotal
        let atCeiling = try XCTUnwrap(ProgressSynthesis.todos(total: ceiling, current: 1, label: "x"))
        XCTAssertEqual(atCeiling.count, ceiling)
        XCTAssertNil(ProgressSynthesis.todos(total: ceiling + 1, current: 1, label: "x"))
        XCTAssertNil(ProgressSynthesis.todos(total: .max, current: 1, label: "x"))
    }
}
