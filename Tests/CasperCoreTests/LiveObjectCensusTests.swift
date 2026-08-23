#if DEBUG
import XCTest
@testable import CasperCore

@MainActor
final class LiveObjectCensusTests: XCTestCase {
    private final class Probe {}

    /// The census is process-global, so every test tracks under its own label and
    /// only ever reads that label back.
    private func entry(for label: String) -> LiveObjectCensus.Entry? {
        LiveObjectCensus.snapshot().first { $0.label == label }
    }

    func testLiveCountDropsToZeroWhileCreatedPersists() throws {
        let label = "probe.release-cycle"
        var probe: Probe? = Probe()
        LiveObjectCensus.track(try XCTUnwrap(probe), label: label)

        let tracked = try XCTUnwrap(entry(for: label))
        XCTAssertEqual(tracked.live, 1)
        XCTAssertEqual(tracked.created, 1)

        // The census holds its subject weakly, so dropping the last strong
        // reference is all it takes for the object to be reported as gone.
        probe = nil

        let released = try XCTUnwrap(entry(for: label))
        XCTAssertEqual(released.live, 0)
        XCTAssertEqual(released.created, 1)
    }

    func testDefaultLabelIsTheDynamicTypeName() throws {
        let probe = Probe()
        LiveObjectCensus.track(probe)
        // `String(describing:)` on a metatype yields the *unqualified* name, so a
        // type nested in this test case is still just "Probe" — `String(reflecting:)`
        // is the one that would spell out `LiveObjectCensusTests.Probe`.
        XCTAssertNotNil(entry(for: "Probe"))
        withExtendedLifetime(probe) {}
    }

    func testRepeatedCyclesDoNotGrowTheStorage() throws {
        let label = "probe.churn"
        // Compact first, so the baseline excludes slots other tests left behind.
        _ = LiveObjectCensus.snapshot()
        let baseline = LiveObjectCensus.slotCount

        for _ in 0..<100 {
            LiveObjectCensus.track(Probe(), label: label)
        }

        let churned = try XCTUnwrap(entry(for: label))
        XCTAssertEqual(churned.live, 0)
        XCTAssertEqual(churned.created, 100)
        // That snapshot reaped every dead slot, so the storage is back to the live
        // population rather than holding everything ever tracked.
        XCTAssertEqual(LiveObjectCensus.slotCount, baseline)
    }

    func testTrackingAloneBoundsTheStorageWithoutAnySnapshot() throws {
        let label = "probe.unsampled"
        // Compact first, so the baseline excludes slots other tests left behind.
        _ = LiveObjectCensus.snapshot()
        let baseline = LiveObjectCensus.slotCount

        // Deliberately no `snapshot()` inside the loop: a debug session that never
        // samples is exactly the case where compaction has to come from `track(_:)`
        // itself, or the census grows the footprint it is meant to report.
        let tracked = 10_000
        for _ in 0..<tracked {
            LiveObjectCensus.track(Probe(), label: label)
        }

        // The bound is a function of the live population (still `baseline`, since
        // every probe dies at the end of its own statement), not of `tracked`.
        XCTAssertLessThan(LiveObjectCensus.slotCount, baseline + tracked / 10)
    }
}
#endif
