#if DEBUG

import Foundation
import os

/// Temporary freeze-diagnosis scaffolding. **DEBUG builds only** — the whole file
/// is compiled out of release, so a distributed build contains none of it.
///
/// Casper intermittently beachballs (spinning-wheel, main thread blocked), and we
/// do not yet have a reliable reproduction. This watchdog detects a hung main
/// thread and, on the first stall of an episode, spawns `/usr/bin/sample` against
/// our own process so the resulting stack dump reveals what the main thread is
/// blocked on.
///
/// Remove this file — and its wiring in `AppDelegate` — once the hang is
/// root-caused. This is a sibling to the `Repository.diffWorkdirToHead` SIGBUS
/// guard (`CSigbusGuard` / `SigbusGuard.run`): both are last-resort instrumentation
/// for hard-to-catch crashes/freezes around the diff view — the SIGBUS guard still
/// ships in release, this one does not. If the captured samples repeatedly point at
/// the diff/libgit2 path, start there.
///
/// Detection uses an inverted heartbeat. A `DispatchSourceTimer` on a dedicated
/// background queue — never blocked by the main thread — fires every 500 ms. Each
/// tick enqueues a block on the main thread's *run loop* that records "the main
/// thread was alive as of this tick's timestamp", then measures how long ago the
/// main thread last acknowledged. While the main thread is stuck, it never turns
/// its run loop, so the pending acknowledgements never run and the measured gap
/// grows until it crosses the threshold and we capture. See `scheduleAck` for why
/// the ack rides the run loop rather than the main dispatch queue.
///
/// `@unchecked Sendable`: the `DispatchSourceTimer` is confined to the serial
/// `queue`, and every other piece of mutable state — the detection counters and the
/// injectable test seams alike — lives behind the `OSAllocatedUnfairLock`, the
/// project's established concurrency idiom (see `SocketServerEngine`).
public final class MainThreadHangWatchdog: @unchecked Sendable {
    /// Environment override for the hang threshold, in seconds. Ignored unless it
    /// parses to a value greater than zero.
    static let thresholdEnvKey = "CASPER_HANG_THRESHOLD"
    /// Environment kill switch. Set to `0`/`false` to make `start()` a no-op — a
    /// safety valve so the diagnostic can be disabled without a rebuild.
    static let enabledEnvKey = "CASPER_HANG_WATCHDOG"

    /// How often the background timer fires. Well below the threshold so a stall
    /// is noticed promptly.
    private static let tickInterval: TimeInterval = 0.5

    /// The two nested-loop modes AppKit spins on its own: modal sessions
    /// (`NSModalPanelRunLoopMode`) and menu / drag tracking
    /// (`NSEventTrackingRunLoopMode`). Spelled as literals because
    /// `RunLoop.Mode.modalPanel` / `.eventTracking` are declared by AppKit, and
    /// CasperCore deliberately does not link AppKit. The raw values are part of
    /// AppKit's public API and have been stable since NeXTSTEP.
    static let modalPanelRunLoopMode = "NSModalPanelRunLoopMode"
    static let eventTrackingRunLoopMode = "NSEventTrackingRunLoopMode"

    /// Run loop modes the acknowledgement block is enqueued for: the common modes
    /// (normal event processing) plus the two nested-loop modes above. See
    /// `scheduleAck`.
    ///
    /// Built once and shared: `scheduleAck` runs twice a second for the whole
    /// process lifetime. `nonisolated(unsafe)` because `CFArray` is not `Sendable`
    /// even though this one is immutable and never handed out.
    nonisolated(unsafe) private static let ackRunLoopModes: CFArray =
        [
            CFRunLoopMode.commonModes.rawValue,
            modalPanelRunLoopMode as CFString,
            eventTrackingRunLoopMode as CFString,
        ] as CFArray

    /// Detection state and the injectable seams, guarded by `lock`. The detection
    /// fields are touched from both the timer queue and the (possibly recovered)
    /// main-thread ack block; the seams are written from a test's thread and read
    /// from the timer queue. Neither is confined to a single queue, so both live
    /// behind the same lock. The seams are documented on their accessors below.
    private struct State {
        var threshold: TimeInterval
        var lastMainAck: TimeInterval
        /// True once this hang episode has produced a capture; reset when the main
        /// thread recovers (gap drops back below the threshold), re-arming the next
        /// episode. Enforces at most one capture per episode.
        var episodeCaptured = false
        /// True while a capture is running, so a fresh episode that begins before
        /// the previous `sample` finishes does not overlap it.
        var captureInFlight = false
        var nowProvider = MainThreadHangWatchdog.defaultNowProvider
        var scheduleAck = MainThreadHangWatchdog.defaultScheduleAck
        var captureDispatch: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
        var capture: (@Sendable (_ hangDuration: TimeInterval, _ destination: URL) -> Void)?
    }

    private let lock: OSAllocatedUnfairLock<State>

    /// Dedicated serial queue that owns the timer. Never blocked by the main
    /// thread, so ticks keep firing throughout a hang.
    private let queue = DispatchQueue(label: "com.github.alexandreroman.casper.hang-watchdog")
    /// Separate queue for the (multi-second) `sample` subprocess so a capture never
    /// stalls the detection timer.
    private let captureQueue = DispatchQueue(
        label: "com.github.alexandreroman.casper.hang-watchdog.capture", qos: .utility)
    /// The active timer, created lazily by `start()`. Confined to `queue`.
    private var timer: DispatchSourceTimer?

    private let onHangCaptured: @Sendable (URL) -> Void

    // MARK: Injectable seams (internal, production defaults)
    //
    // These exist purely so the detection state machine can be driven
    // deterministically in tests — with a fake clock, a manual ack toggle and a
    // stubbed capture — without a real timer, a real blocked main thread or a real
    // `sample` subprocess. Production code never overrides them.
    //
    // Each is an accessor over the lock-guarded `State`, so a test assigning one
    // from its own thread does not race the timer queue reading it.

    /// Monotonic clock reading, in seconds. Monotonic (not wall-clock) so a system
    /// clock change cannot manufacture a phantom hang.
    static let defaultNowProvider: @Sendable () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }

    var nowProvider: @Sendable () -> TimeInterval {
        get { lock.withLock { $0.nowProvider } }
        set { lock.withLock { $0.nowProvider = newValue } }
    }

    /// Schedules the per-tick acknowledgement block onto the main thread: it is
    /// enqueued on the main *run loop*, for `ackRunLoopModes`, so a main thread that
    /// has stopped turning its run loop simply never runs it.
    ///
    /// The obvious implementation — and the original one — was
    /// `DispatchQueue.main.async`, but it cried wolf. Choosing "Check for
    /// Updates…" makes Sparkle call `-[NSAlert runModal]` from inside a main
    /// queue block, which spins a nested modal run loop and sits there waiting
    /// for the user. libdispatch will not re-enter `_dispatch_main_queue_drain`
    /// from that nested loop, so every queued ack stays stuck behind the alert:
    /// the gap crossed the threshold and the watchdog sampled a perfectly healthy
    /// app (captured dump `hang-20260727-115846.txt`, main thread parked in
    /// `-[NSApplication _doModalLoop:peek:]`). Casper's own `runModal()` panels
    /// and alerts in `AppModel+Presentation` and plain menu tracking have the
    /// exact same shape. Run loop blocks carry no such re-entrancy guard: the
    /// nested loop drains them, so acks keep flowing while a modal is up.
    ///
    /// Accepted trade-off: the watchdog no longer notices "the main dispatch
    /// queue is not draining" on its own — only "the main thread is not turning
    /// its run loop at all". So a genuine hang whose signature is a nested loop
    /// spinning forever while ordinary main queue work starves — a modal session
    /// or a menu track that never ends — now reads as healthy. That is the price
    /// of not crying wolf on every alert the user opens. (A hard block, where the
    /// thread stops servicing any loop, is still caught.)
    static let defaultScheduleAck: @Sendable (@escaping @Sendable () -> Void) -> Void = { block in
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, MainThreadHangWatchdog.ackRunLoopModes, block)
        // A run loop asleep in `mach_msg` would not notice the block until its
        // next event — which, on an idle app, may be seconds away and would look
        // exactly like a hang. Wake it so the ack lands within this tick.
        CFRunLoopWakeUp(mainRunLoop)
    }

    var scheduleAck: @Sendable (@escaping @Sendable () -> Void) -> Void {
        get { lock.withLock { $0.scheduleAck } }
        set { lock.withLock { $0.scheduleAck = newValue } }
    }

    /// Dispatches the (blocking) capture work off the detection timer's queue. The
    /// default uses `captureQueue`; a test runs it inline for determinism.
    var captureDispatch: (@Sendable (@escaping @Sendable () -> Void) -> Void)? {
        get { lock.withLock { $0.captureDispatch } }
        set { lock.withLock { $0.captureDispatch = newValue } }
    }

    /// Performs the capture for a detected hang of `hangDuration`, writing the dump
    /// to `destination`. The default runs `sample`; a test stubs it to record the
    /// call. Set to the real implementation in `init`.
    var capture: (@Sendable (_ hangDuration: TimeInterval, _ destination: URL) -> Void)? {
        get { lock.withLock { $0.capture } }
        set { lock.withLock { $0.capture = newValue } }
    }

    /// - Parameters:
    ///   - threshold: how long the main thread may be unresponsive before a capture
    ///     is triggered. Overridden by `CASPER_HANG_THRESHOLD` in `start()`.
    ///   - onHangCaptured: invoked (on a background thread) with the written dump
    ///     file once a capture completes. Defaults to a no-op.
    public init(
        threshold: TimeInterval = 2.0,
        onHangCaptured: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.onHangCaptured = onHangCaptured
        // `lastMainAck` starts neutral; `start()` re-baselines it from the clock
        // before the first tick runs, so this value never triggers a phantom hang.
        self.lock = OSAllocatedUnfairLock(initialState: State(threshold: threshold, lastMainAck: 0))
        // These two defaults need `self`, so they cannot be State field defaults.
        self.lock.withLock { state in
            state.captureDispatch = { [captureQueue] block in captureQueue.async(execute: block) }
            state.capture = { [weak self] hangDuration, destination in
                self?.performDefaultCapture(hangDuration: hangDuration, destination: destination)
            }
        }
    }

    /// Starts the detection timer. Idempotent, and safe to call from any thread.
    /// Reads the environment overrides here so no rebuild is needed to retune or
    /// disable the diagnostic.
    public func start() {
        let environment = ProcessInfo.processInfo.environment
        if let flag = environment[Self.enabledEnvKey]?.lowercased(), flag == "0" || flag == "false" {
            CasperLog.app.info("main-thread hang watchdog disabled via \(Self.enabledEnvKey, privacy: .public)")
            return
        }
        let resolvedThreshold: TimeInterval? = {
            guard let raw = environment[Self.thresholdEnvKey], let value = Double(raw), value > 0 else { return nil }
            return value
        }()

        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }  // idempotent

            // Read the clock before taking the lock: the seam is an injected closure,
            // and calling one under the lock invites a lock-ordering surprise.
            let now = self.nowProvider()
            self.lock.withLock { state in
                if let resolvedThreshold { state.threshold = resolvedThreshold }
                // Re-baseline the ack so time spent before `start()` cannot count as a hang.
                state.lastMainAck = now
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
            timer.setEventHandler { [weak self] in self?.handleTick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops the detection timer and tears down cleanly. The trailing `queue.sync`
    /// barrier guarantees any tick already in flight has fully returned — and can
    /// no longer start a capture — before `stop()` returns.
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
        queue.sync {}
    }

    // MARK: Detection state machine

    /// One timer tick: (a) ask the main thread to acknowledge as of `now`, and
    /// (b) evaluate how long it has been silent. Runs on `queue`; also the single
    /// entry point a test drives synchronously.
    func handleTick() {
        let now = nowProvider()
        scheduleAck { [weak self] in self?.recordAck(at: now) }
        if case .capture(let hangDuration) = evaluate(now: now) {
            dispatchCapture(hangDuration: hangDuration)
        }
    }

    /// Records that the main thread was alive as of `ackTime`. Called from the
    /// block `scheduleAck` runs on the main thread. Ack blocks are drained by the
    /// run loop in the order they were enqueued and carry a monotonic timestamp,
    /// so a plain assignment always advances `lastMainAck`.
    func recordAck(at ackTime: TimeInterval) {
        lock.withLock { $0.lastMainAck = ackTime }
    }

    private enum TickDecision {
        case idle
        case capture(hangDuration: TimeInterval)
    }

    /// Pure decision step over the shared state: re-arm when the main thread is
    /// healthy, otherwise trigger at most one capture per hang episode.
    private func evaluate(now: TimeInterval) -> TickDecision {
        lock.withLock { state in
            let elapsed = now - state.lastMainAck
            if elapsed < state.threshold {
                state.episodeCaptured = false  // main thread is responsive again → re-arm
                return .idle
            }
            guard !state.episodeCaptured, !state.captureInFlight else { return .idle }
            state.episodeCaptured = true
            state.captureInFlight = true
            return .capture(hangDuration: elapsed)
        }
    }

    /// Runs the capture off the timer queue, then clears the in-flight flag so a
    /// later episode can capture again.
    private func dispatchCapture(hangDuration: TimeInterval) {
        // `evaluate` already set `captureInFlight`, and only the work block below
        // clears it. With no dispatcher there is no work block, so clear it here or
        // the watchdog stays armed-but-mute for the rest of the process's life.
        guard let captureDispatch else {
            lock.withLock { $0.captureInFlight = false }
            return
        }
        let destination = Self.dumpDestination(at: Date())
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.capture?(hangDuration, destination)
            self.lock.withLock { $0.captureInFlight = false }
        }
        captureDispatch(work)
    }

    // MARK: Default capture (the real `sample` run)

    /// Builds the dump file URL under `~/Library/Logs/Casper/`, timestamped with a
    /// filesystem-safe `yyyyMMdd-HHmmss` string.
    private static func dumpDestination(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Casper", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Casper", isDirectory: true)
        return directory.appendingPathComponent("hang-\(formatter.string(from: date)).txt", isDirectory: false)
    }

    /// Default capture: log a marker first (so we always have a record even if the
    /// subprocess fails), then run `/usr/bin/sample` and confirm the written path.
    private func performDefaultCapture(hangDuration: TimeInterval, destination: URL) {
        // Emit the marker BEFORE anything can fail, so the unified log always
        // carries the hang duration and intended dump path even if `sample` never
        // runs. `.fault` makes it stand out in the unified log.
        CasperLog.app.fault(
            """
            main-thread hang detected: unresponsive for \
            \(String(format: "%.2f", hangDuration), privacy: .public)s; \
            sampling to \(destination.path, privacy: .public)
            """)

        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            CasperLog.app.failure("hang watchdog could not create dump directory", error)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // `sample <pid> <duration> -file <path>`: profile our own process for 3s.
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", destination.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CasperLog.app.failure("hang watchdog failed to launch /usr/bin/sample", error)
            return
        }
        guard process.terminationStatus == 0 else {
            CasperLog.app.error(
                "hang watchdog: /usr/bin/sample exited with status \(process.terminationStatus, privacy: .public)")
            return
        }

        CasperLog.app.fault("main-thread hang sample written to \(destination.path, privacy: .public)")
        onHangCaptured(destination)
    }
}

#endif  // DEBUG
