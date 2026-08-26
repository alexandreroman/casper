#if DEBUG
import Darwin

/// Reads the process's own memory accounting from the Mach kernel, so a churn
/// test can watch the footprint instead of reading Activity Monitor by eye.
public enum ProcessMemory {
    public struct Sample: Equatable, Sendable {
        /// `phys_footprint` — the number Activity Monitor shows as "Memory".
        public var footprintBytes: Int
        /// `resident_size` — physical pages currently mapped in.
        public var residentBytes: Int
        /// `ledger_phys_footprint_peak`, or 0 when the kernel does not report it.
        public var peakFootprintBytes: Int

        public init(footprintBytes: Int, residentBytes: Int, peakFootprintBytes: Int) {
            self.footprintBytes = footprintBytes
            self.residentBytes = residentBytes
            self.peakFootprintBytes = peakFootprintBytes
        }
    }

    /// The current sample, or `nil` when `task_info` fails.
    ///
    /// Optional rather than an all-zero `Sample` so a failed reading cannot be
    /// mistaken for a healthy 0 MB one: callers have to answer for the failure. It
    /// never traps either way — an observability hook must not take the process
    /// down.
    public static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        // `TASK_VM_INFO_COUNT` is a C macro and does not import into Swift, so the
        // word count is derived from the layout the same way the macro does.
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return Sample(
            footprintBytes: Int(info.phys_footprint),
            residentBytes: Int(info.resident_size),
            peakFootprintBytes: peakFootprint(of: info, filledWords: count))
    }

    /// `ledger_phys_footprint_peak` sits in a later revision of the `task_vm_info`
    /// layout than the fields above it. `task_info` writes back how many words it
    /// actually filled, so a kernel that predates the field is detected here rather
    /// than read as uninitialized memory.
    private static func peakFootprint(
        of info: task_vm_info_data_t, filledWords: mach_msg_type_number_t
    ) -> Int {
        guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)
        else { return 0 }
        let wordsNeeded = (offset + MemoryLayout<Int64>.size) / MemoryLayout<natural_t>.size
        guard filledWords >= mach_msg_type_number_t(wordsNeeded) else { return 0 }
        return Int(info.ledger_phys_footprint_peak)
    }
}
#endif
