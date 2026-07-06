import XCTest
@testable import CasperCore

final class PortAllocatorTests: XCTestCase {
    func testAllocateReturnsSequentialBlocks() throws {
        var a = PortAllocator()
        XCTAssertEqual(try a.allocate(), 40000)
        XCTAssertEqual(try a.allocate(), 40010)
        XCTAssertEqual(try a.allocate(), 40020)
    }

    func testReserveSkipsRestoredBase() throws {
        var a = PortAllocator()
        XCTAssertTrue(a.reserve(40000))
        XCTAssertEqual(try a.allocate(), 40010)
    }

    func testReserveRejectsMisalignedOrOutOfRange() {
        var a = PortAllocator()
        XCTAssertFalse(a.reserve(40005)) // not a multiple of blockSize from start
        XCTAssertFalse(a.reserve(39990)) // below range
        XCTAssertFalse(a.reserve(50000)) // above range
    }

    func testReleaseAllowsReuse() throws {
        var a = PortAllocator()
        let first = try a.allocate()   // 40000
        _ = try a.allocate()           // 40010
        a.release(first)
        XCTAssertEqual(try a.allocate(), 40000) // reuses the freed lowest block
    }

    func testExhaustionThrows() {
        var a = PortAllocator(rangeStart: 40000, rangeEnd: 40010, blockSize: 10)
        XCTAssertNoThrow(try a.allocate()) // 40000
        XCTAssertNoThrow(try a.allocate()) // 40010
        XCTAssertThrowsError(try a.allocate()) { error in
            XCTAssertTrue(error is PortAllocationError)
        }
    }

    func testDoubleReserveReturnsFalse() {
        var a = PortAllocator()
        XCTAssertTrue(a.reserve(40000))
        XCTAssertFalse(a.reserve(40000)) // already reserved → not inserted again
    }

    func testReserveAtRangeEndSucceedsAndBeyondFails() {
        var a = PortAllocator(rangeStart: 40000, rangeEnd: 40010, blockSize: 10)
        XCTAssertTrue(a.reserve(40010))  // exact last block base is in range
        XCTAssertFalse(a.reserve(40020)) // one block past rangeEnd is out of range
    }

    func testAllocateWrapsAroundFromStartBase() throws {
        var a = PortAllocator(rangeStart: 40000, rangeEnd: 40030, blockSize: 10, startBase: 40020)
        XCTAssertEqual(try a.allocate(), 40020)
        XCTAssertEqual(try a.allocate(), 40030)
        XCTAssertEqual(try a.allocate(), 40000) // wrapped
        XCTAssertEqual(try a.allocate(), 40010)
        XCTAssertThrowsError(try a.allocate())  // exhausted
    }

    func testRandomStartBaseIsAlignedAndInRange() {
        for _ in 0..<1000 {
            let base = PortAllocator.randomStartBase()
            XCTAssertGreaterThanOrEqual(base, 40000)
            XCTAssertLessThanOrEqual(base, 49990)
            XCTAssertEqual((base - 40000) % 10, 0)
        }
    }

    func testDifferentStartsDoNotCollideOnFirstAllocation() throws {
        var a = PortAllocator(startBase: 40000)
        var b = PortAllocator(startBase: 40500)
        XCTAssertNotEqual(try a.allocate(), try b.allocate())
    }
}
