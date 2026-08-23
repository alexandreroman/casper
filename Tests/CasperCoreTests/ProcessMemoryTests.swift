#if DEBUG
import XCTest
@testable import CasperCore

final class ProcessMemoryTests: XCTestCase {
    func testSampleReportsTheRunningProcessFootprint() throws {
        // `nil` means `task_info` failed, which would make every field meaningless.
        let sample = try XCTUnwrap(ProcessMemory.sample())
        // A running process always has a footprint.
        XCTAssertGreaterThan(sample.footprintBytes, 0)
        XCTAssertGreaterThan(sample.residentBytes, 0)
        // The peak is documented as 0 on a kernel that does not report the field,
        // so only a *reported* peak is required to bound the current footprint.
        XCTAssertTrue(
            sample.peakFootprintBytes == 0 || sample.peakFootprintBytes >= sample.footprintBytes,
            "peak \(sample.peakFootprintBytes) is neither unreported nor >= footprint "
                + "\(sample.footprintBytes)")
    }
}
#endif
