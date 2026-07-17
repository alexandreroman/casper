import Foundation
import os

/// Temporary freeze-diagnosis scaffolding.
///
/// Casper intermittently beachballs (spinning-wheel, main thread blocked) on real
/// release builds, and we do not yet have a reliable reproduction. This watchdog
/// detects a hung main thread and, on the first stall of an episode, spawns
/// `/usr/bin/sample` against our own process so the resulting stack dump reveals
/// what the main thread is blocked on. It is deliberately compiled into release
/// builds (NO `#if DEBUG` gating) so we can catch the freeze in the field.
///
/// Remove this file — and its wiring in `AppDelegate` — once the hang is
/// root-caused. This is a sibling to the `Repository.diffWorkdirToHead` SIGBUS
/// guard (`CSigbusGuard` / `SigbusGuard.run`): both are last-resort field
/// instrumentation for hard-to-catch crashes/freezes around the diff view. If the
/// captured samples repeatedly point at the diff/libgit2 path, start there.
///
/// Detection uses an inverted heartbeat. A `DispatchSourceTimer` on a dedicated
/// background queue — never blocked by the main thread — fires every 500 ms. Each
/// tick schedules a block on the main queue that records "the main thread was
/// alive as of this tick's timestamp", then measures how long ago the main thread
/// last acknowledged. While the main thread spins, its queued acknowledgements
/// never run, so the measured gap grows until it crosses the threshold and we
/// capture.
///
/// `@unchecked Sendable`: the timer's `DispatchSourceTimer` and shared detection
/// state are confined to the serial `queue` / the `OSAllocatedUnfairLock`, the
/// project's established concurrency idiom (see `SocketServerEngine`).
public final class MainThreadHangWatchdog: @unchecked Sendable {
    /// Environment override for the hang threshold, in seconds. Ignored unless it
    /// parses to a value greater than zero.
    static let thresholdEnvKey = "CASPER_HANG_THRESHOLD"
    /// Environment kill switch. Set to `0`/`false` to make `start()` a no-op — a
    /// safety valve so the diagnostic can be disabled in the field without a
    /// rebuild.
    static let enabledEnvKey = "CASPER_HANG_WATCHDOG"

    /// How often the background timer fires. Well below the threshold so a stall
    /// is noticed promptly.
    private static let tickInterval: TimeInterval = 0.5

    /// Detection state, guarded by `lock`. All of it is touched from both the
    /// timer queue and the (possibly recovered) main-thread ack block, so it lives
    /// behind a single lock rather than being confined to one queue.
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

    /// Monotonic clock reading, in seconds. Monotonic (not wall-clock) so a system
    /// clock change cannot manufacture a phantom hang.
    var nowProvider: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Schedules the per-tick acknowledgement block onto the main thread. The
    /// default hops to the main queue; a hung main thread simply never runs it.
    var scheduleAck: @Sendable (@escaping @Sendable () -> Void) -> Void = { block in
        DispatchQueue.main.async(execute: block)
    }
    /// Dispatches the (blocking) capture work off the detection timer's queue. The
    /// default uses `captureQueue`; a test runs it inline for determinism.
    var captureDispatch: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    /// Performs the capture for a detected hang of `hangDuration`, writing the dump
    /// to `destination`. The default runs `sample`; a test stubs it to record the
    /// call. Set to the real implementation in `init`.
    var capture: (@Sendable (_ hangDuration: TimeInterval, _ destination: URL) -> Void)?

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
        self.captureDispatch = { [captureQueue] block in captureQueue.async(execute: block) }
        self.capture = { [weak self] hangDuration, destination in
            self?.performDefaultCapture(hangDuration: hangDuration, destination: destination)
        }
    }

    /// Starts the detection timer. Idempotent, and safe to call from any thread.
    /// Reads the environment overrides here so no rebuild is needed to retune or
    /// disable the diagnostic in the field.
    public func start() {
        let environment = ProcessInfo.processInfo.environment
        if let flag = environment[Self.enabledEnvKey]?.lowercased(), flag == "0" || flag == "false" {
            CasperLog.app.fault("main-thread hang watchdog disabled via \(Self.enabledEnvKey, privacy: .public)")
            return
        }
        let resolvedThreshold: TimeInterval? = {
            guard let raw = environment[Self.thresholdEnvKey], let value = Double(raw), value > 0 else { return nil }
            return value
        }()

        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }  // idempotent

            self.lock.withLock { state in
                if let resolvedThreshold { state.threshold = resolvedThreshold }
                // Re-baseline the ack so time spent before `start()` cannot count as a hang.
                state.lastMainAck = self.nowProvider()
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
    /// block `scheduleAck` runs on the main thread. Ack blocks are delivered in
    /// order on the serial main queue and carry a monotonic timestamp, so a plain
    /// assignment always advances `lastMainAck`.
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
        let destination = Self.dumpDestination(at: Date())
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.capture?(hangDuration, destination)
            self.lock.withLock { $0.captureInFlight = false }
        }
        captureDispatch?(work)
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
        // runs. `.fault` keeps it in release builds and highly visible.
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
