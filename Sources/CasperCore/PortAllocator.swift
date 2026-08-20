/// Thrown by `PortAllocator.allocate()` when the range holds no free block.
/// Public because `allocate()` is: a cross-module caller must be able to catch it.
public struct PortAllocationError: Error, Equatable {
    public let reason: String
}

public struct PortAllocator: Equatable, Sendable {
    /// Default block geometry, shared by `init` and `randomStartBase` so the two
    /// can never disagree: a one-sided edit would make `randomStartBase` return a
    /// base outside a default-constructed allocator's range, which `init` rejects
    /// with a `precondition` (a startup crash).
    public static let defaultRangeStart = 40000
    public static let defaultRangeEnd = 49990
    public static let defaultBlockSize = 10

    /// Lowest allowed block base.
    public let rangeStart: Int
    /// Highest allowed block *base* — not the highest allocatable port. Each
    /// block occupies the `blockSize` ports `[base, base + blockSize - 1]`, so a
    /// block anchored at `rangeEnd` can extend up to `blockSize - 1` ports past
    /// `rangeEnd`. Size the range so that tail fits within the intended ceiling.
    public let rangeEnd: Int
    public let blockSize: Int
    /// First block base `allocate()` scans; it wraps around from here. Defaults
    /// to `rangeStart` (historical sequential behavior). The app seeds it with a
    /// random value (`randomStartBase`) so two concurrent instances statistically
    /// hand out different blocks to their first workspaces.
    private let startBase: Int
    private var used: Set<Int>

    /// The `precondition`s assume trusted, code-constant arguments. Callers
    /// constructing an allocator from external or persisted input must validate
    /// the range and block size first, since a violation traps rather than throws.
    public init(rangeStart: Int = PortAllocator.defaultRangeStart,
                rangeEnd: Int = PortAllocator.defaultRangeEnd,
                blockSize: Int = PortAllocator.defaultBlockSize,
                startBase: Int? = nil) {
        precondition(blockSize > 0, "blockSize must be positive")
        precondition(rangeEnd >= rangeStart, "rangeEnd must be >= rangeStart")
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.blockSize = blockSize
        if let startBase {
            precondition(startBase >= rangeStart && startBase <= rangeEnd
                && (startBase - rangeStart) % blockSize == 0,
                "startBase must be an aligned, in-range block base")
            self.startBase = startBase
        } else {
            self.startBase = rangeStart
        }
        self.used = []
    }

    /// Number of aligned block bases in `[rangeStart, rangeEnd]`. Static so
    /// `randomStartBase`, which has no instance, can share it with `allocate()`.
    private static func blockCount(rangeStart: Int, rangeEnd: Int, blockSize: Int) -> Int {
        (rangeEnd - rangeStart) / blockSize + 1
    }

    /// A random aligned block base within `[rangeStart, rangeEnd]`, for seeding a
    /// per-instance `startBase`.
    public static func randomStartBase(rangeStart: Int = PortAllocator.defaultRangeStart,
                                       rangeEnd: Int = PortAllocator.defaultRangeEnd,
                                       blockSize: Int = PortAllocator.defaultBlockSize) -> Int {
        let blockCount = blockCount(rangeStart: rangeStart, rangeEnd: rangeEnd, blockSize: blockSize)
        return rangeStart + Int.random(in: 0..<blockCount) * blockSize
    }

    @discardableResult
    public mutating func reserve(_ base: Int) -> Bool {
        guard base >= rangeStart, base <= rangeEnd,
              (base - rangeStart) % blockSize == 0 else { return false }
        return used.insert(base).inserted
    }

    public mutating func release(_ base: Int) {
        used.remove(base)
    }

    public mutating func allocate() throws -> Int {
        let startIndex = (startBase - rangeStart) / blockSize
        let blockCount = Self.blockCount(rangeStart: rangeStart, rangeEnd: rangeEnd, blockSize: blockSize)
        for i in 0..<blockCount {
            let base = rangeStart + ((startIndex + i) % blockCount) * blockSize
            if used.insert(base).inserted { return base }
        }
        throw PortAllocationError(
            reason: "no free \(blockSize)-port block in \(rangeStart)...\(rangeEnd)"
        )
    }
}
