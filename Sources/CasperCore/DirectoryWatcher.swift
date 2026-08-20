import CoreServices
import Foundation

/// A native FSEvents wrapper that watches a path subtree and delivers coalesced
/// change notifications. Deliberately model-free: it knows nothing of
/// `Workspace`, `Repository`, `GitDiff`, or SwiftUI, and depends only on
/// Foundation + CoreServices. The caller supplies a `path`, optional exclusion
/// paths, and a `@Sendable` callback; the callback runs on a private serial
/// queue, so hopping to the main actor is the caller's responsibility.
///
/// Concurrency (Swift 6): the class is `@unchecked Sendable`. The stream runs on
/// a dedicated serial `DispatchQueue` via `FSEventStreamSetDispatchQueue`, and
/// the C callback is a top-level function pointer that reconstructs the instance
/// from the stream context. This mirrors the `NWListener` discipline captured in
/// the `swift6-network-concurrency` project-memory note. `onChange` is set once
/// at init and never mutated, and `stop()`/`deinit` invalidate the stream before
/// the instance dies, so the unretained context pointer stays valid for the
/// stream's lifetime.
public final class DirectoryWatcher: @unchecked Sendable {
    /// Invoked on `queue` for every coalesced batch of filesystem changes. The
    /// event paths are ignored on purpose: callers recompute state wholesale.
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "casper.directory-watcher")
    /// Marks `queue` so `stop()` can recognize it is already running on it and
    /// skip the `queue.sync` barrier, which would otherwise deadlock. The key is
    /// per-instance (not static) so one watcher's queue never reads as another's.
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?

    /// Start watching `path` (recursively). Returns nil if the FSEvents stream
    /// cannot be created. `latency` is the FSEvents coalescing window; the real
    /// smoothing is expected to happen application-side.
    public init?(
        path: String,
        excluding exclusions: [String] = [],
        latency: TimeInterval = 0.05,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)

        // FSEvents needs canonical, symlink-free paths: a watched path that
        // traverses a symlink (e.g. /var -> /private/var, /tmp -> /private/tmp)
        // silently delivers no events, and an exclusion path that isn't
        // canonicalized the same way fails to match — so git's own writes under
        // an un-resolved `.git` exclusion would still wake the watcher. Resolve
        // both the root and every exclusion through the same canonicalization.
        let canonicalPath = Self.canonicalize(path)

        // Unretained: the owner holds the watcher strongly, and stop()/deinit
        // invalidate the stream before the instance dies. This avoids a retain
        // cycle and any leak on init failure.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        // Directory-level granularity (no FileEvents): we recompute the whole
        // diff on any change, so coarse-grained callbacks mean fewer wake-ups.
        // `IgnoreSelf` is deliberately omitted: it suppresses events triggered
        // by the current process, which would drop both same-process test writes
        // and legitimate in-process libgit2 writes (e.g. `git init` promotion).
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            nil,
            directoryWatcherCallback,
            &context,
            [canonicalPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        self.stream = stream

        if !exclusions.isEmpty {
            let canonicalExclusions = exclusions.map(Self.canonicalize)
            FSEventStreamSetExclusionPaths(stream, canonicalExclusions as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        // A stream that never starts fires no callbacks — an explicit init
        // failure is better than a silently dead watcher. Tear it down and fail.
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    /// Canonicalize a filesystem path with realpath(3), stripping symlinks so
    /// FSEvents can match it. Falls back to the original path when it does not
    /// resolve yet (realpath returns null, e.g. the path does not exist).
    private static func canonicalize(_ path: String) -> String {
        path.withCString { cPath -> String in
            guard let resolved = realpath(cPath, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Stop, invalidate, and release the stream. Idempotent.
    ///
    /// Expected to be called from outside the callback `queue` (in practice, from
    /// the main actor via the owner's reconfigure path or `deinit`). The trailing
    /// `queue.sync {}` barrier lets any in-flight or queued callback drain on the
    /// serial queue before teardown returns, closing the use-after-free window
    /// against the unretained context. The owner's `onChange` hop uses
    /// `DispatchQueue.main.async` (non-blocking), so it never blocks the queue and
    /// cannot deadlock with this barrier.
    ///
    /// Calling it *from* `queue` would self-deadlock on that barrier, and `deinit`
    /// can legitimately land there — releasing the last reference inside the
    /// callback destroys the instance on the callback queue. So detect that case
    /// via the queue's `DispatchSpecificKey` and tear down inline: on `queue`, the
    /// current callback *is* the only in-flight one, so there is nothing left to
    /// drain and the barrier's guarantee already holds.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        // Barrier: drain any running/queued callback before returning, so no
        // callback can touch a deallocating instance after stop().
        queue.sync {}
    }

    deinit {
        stop()
    }

    fileprivate func handleChange() {
        onChange()
    }
}

/// Top-level C callback: reconstruct the watcher from the unretained context
/// pointer and forward the change. The event path array is ignored — callers
/// recompute wholesale.
private func directoryWatcherCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    watcher.handleChange()
}

/// Abstraction over a directory watcher so consumers depend on the capability,
/// not the concrete FSEvents type (and can inject a stub in tests).
public protocol DirectoryWatching: AnyObject, Sendable {
    func stop()
}

extension DirectoryWatcher: DirectoryWatching {}
