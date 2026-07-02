import Foundation

public struct PortAllocationError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct PortAllocator: Equatable, Sendable {
    public let rangeStart: Int
    public let rangeEnd: Int
    public let blockSize: Int
    private var used: Set<Int>

    /// The `precondition`s assume trusted, code-constant arguments. Callers
    /// constructing an allocator from external or persisted input must validate
    /// the range and block size first, since a violation traps rather than throws.
    public init(rangeStart: Int = 40000, rangeEnd: Int = 49990, blockSize: Int = 10) {
        precondition(blockSize > 0, "blockSize must be positive")
        precondition(rangeEnd >= rangeStart, "rangeEnd must be >= rangeStart")
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.blockSize = blockSize
        self.used = []
    }

    public var allocatedBases: Set<Int> { used }

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
        for base in stride(from: rangeStart, through: rangeEnd, by: blockSize) {
            if used.insert(base).inserted { return base }
        }
        throw PortAllocationError(
            reason: "no free \(blockSize)-port block in \(rangeStart)...\(rangeEnd)"
        )
    }
}
