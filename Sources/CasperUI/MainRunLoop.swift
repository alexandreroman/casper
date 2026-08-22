import AppKit
import Foundation

/// Hopping onto the main thread on a LATER turn of the main run loop.
///
/// Deliberately not `DispatchQueue.main.async`: while the main thread sits in a nested
/// run loop — which it does whenever `AppModel+Presentation` runs an `NSAlert` or
/// `NSOpenPanel` modally, whenever Sparkle checks for updates, and whenever AppKit
/// tracks a menu or a drag — libdispatch refuses to re-enter the main queue, so a
/// main-queue block waits out the whole panel (the `main-queue-starved-by-modal-loops`
/// note). Run-loop blocks carry no such re-entrancy guard: the nested loop drains them.
///
/// The deferral off the *current* turn survives the switch: `CFRunLoopPerformBlock`
/// enqueues the block for a later pass of the loop, it never runs it inline.
///
/// Counterweight: this route is for work that must run *while* a modal loop is up.
/// Where the hazard is instead re-entering a library mid-tick, the main queue is the
/// right hop precisely because it cannot run inside the current tick.
enum MainRunLoop {
    /// Run `body` on the main thread, on a later turn of its run loop.
    ///
    /// `nonisolated` and `@Sendable` because the whole point is to be callable from
    /// wherever the caller happens to be — an FSEvents queue as readily as the main
    /// actor. The three CoreFoundation calls are thread-safe by design; handing a block
    /// to another thread's run loop is exactly what they are for. `body` carries its own
    /// isolation, and the run loop drains it on the main thread.
    static func perform(_ body: @escaping @Sendable () -> Void) {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, modes, body)
        // A run loop asleep in `mach_msg` would sit on the block until its next event,
        // which on an idle app is however long the user takes to touch the app again.
        CFRunLoopWakeUp(mainRunLoop)
    }

    /// The run loop modes `perform` enqueues for: the common modes for ordinary event
    /// processing, plus the two nested loops AppKit spins on its own (modal sessions and
    /// menu/drag tracking). Built once and shared.
    ///
    /// `nonisolated(unsafe)` because `CFArray` is not `Sendable`, even though this one is
    /// immutable and never handed out.
    nonisolated(unsafe) private static let modes: CFArray = [
        CFRunLoopMode.commonModes.rawValue,
        RunLoop.Mode.modalPanel.rawValue as CFString,
        RunLoop.Mode.eventTracking.rawValue as CFString,
    ] as CFArray
}
