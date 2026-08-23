#if DEBUG
/// Counts live instances of the classes registered with it, so a leak shows up as
/// a population that never comes back down after the objects it belongs to are
/// closed.
///
/// Tracking is entirely external: `track(_:)` stores a **weak** reference, so a
/// tracked class needs neither a token property nor a `deinit` hook, and the
/// census can never keep an object alive. An entry simply zeroes out when its
/// object deallocates.
///
/// Main-actor isolated because that is where the tracked AppKit/SwiftUI objects
/// live; the storage is plain, unsynchronized global state as a result.
@MainActor
public enum LiveObjectCensus {
    /// One label's population: how many instances are alive right now, and how
    /// many have ever been tracked under it.
    public struct Entry: Codable, Equatable, Sendable {
        public var label: String
        public var live: Int
        public var created: Int

        public init(label: String, live: Int, created: Int) {
            self.label = label
            self.live = live
            self.created = created
        }
    }

    /// A weak slot: the tracked object plus the label it was tracked under. The
    /// label is stored here (not only in `createdCounts`) because the object is
    /// gone by the time a slot is reaped, so it can no longer name its own type.
    private final class WeakBox {
        weak var object: AnyObject?
        let label: String

        init(object: AnyObject, label: String) {
            self.object = object
            self.label = label
        }
    }

    private static var boxes: [WeakBox] = []
    private static var createdCounts: [String: Int] = [:]
    /// How many slots survived the last compaction — the live population the next
    /// compaction budget is sized against.
    private static var liveCountAtLastCompaction = 0
    /// Slack added to the doubling budget so a small live population does not
    /// compact on nearly every `track(_:)`.
    private static let compactionFloor = 64

    /// Start tracking `object`, defaulting to its dynamic type name as the label.
    public static func track(_ object: AnyObject, label: String? = nil) {
        // The *dynamic* type, so tracking from a base class's `init` still reports
        // the concrete subclass the caller cares about.
        let label = label ?? String(describing: type(of: object))
        boxes.append(WeakBox(object: object, label: label))
        createdCounts[label, default: 0] += 1

        // Compacting here, and not only in `snapshot()`, is what makes the storage
        // bound unconditional: a debug session that never samples would otherwise
        // keep one slot per object ever tracked, so the instrumentation would grow
        // the very footprint it exists to report.
        //
        // The budget is amortized: a compaction only runs once the array has grown
        // past twice the live population it last measured, so each scan is paid for
        // by at least as many appends as it visits and `track` stays O(1) amortized
        // while `boxes` stays O(live). `compactionFloor` keeps a small population
        // (or an empty one, where doubling buys nothing) from compacting on almost
        // every append.
        if boxes.count > 2 * liveCountAtLastCompaction + compactionFloor {
            compact()
        }
    }

    /// Drop the slots whose object has deallocated, and re-measure the live
    /// population that sizes the next compaction budget.
    private static func compact() {
        boxes.removeAll { $0.object == nil }
        liveCountAtLastCompaction = boxes.count
    }

    /// Live and ever-created counts per label, sorted by label.
    public static func snapshot() -> [Entry] {
        // Required for correctness, not just hygiene: the tally below counts one
        // per surviving slot, so a slot whose object died since the last compaction
        // would otherwise still be reported as live.
        compact()

        var liveCounts: [String: Int] = [:]
        for box in boxes {
            liveCounts[box.label, default: 0] += 1
        }

        // Driven by `createdCounts`, not by the surviving boxes: a label whose
        // population has dropped back to zero is exactly the healthy signal this
        // census exists to show, so it must still be reported.
        return createdCounts
            .map { Entry(label: $0.key, live: liveCounts[$0.key] ?? 0, created: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// Number of weak slots currently retained. Internal on purpose — an
    /// implementation detail the compaction test pins, not part of the census API.
    static var slotCount: Int { boxes.count }
}
#endif
