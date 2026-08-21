import CSigbusGuard

/// A SIGBUS guard around code that touches memory-mapped working-directory files.
///
/// libgit2 `mmap`s working-directory files to diff them. A coding agent that
/// truncates a file after libgit2 maps it but before xdiff reads the mapped
/// pages leaves those pages past the new EOF, and touching them raises a
/// hardware `SIGBUS`. libgit2 installs no signal handler for it, and a signal
/// cannot be caught by a Swift `do`/`catch`, so the fault kills the whole
/// process. Trapping `SIGBUS` with a signal handler plus `sigsetjmp`/
/// `siglongjmp` is the established recovery technique for a truncated-`mmap`
/// fault (see `CSigbusGuard`). This funnels that fault into the same graceful
/// path as libgit2's own stat-based race detection.
///
/// - Important: On the fault path the guard aborts `body` via `siglongjmp`, so
///   the stack frames *inside* `body` are abandoned. Swift `defer` blocks and
///   ARC releases pending in those frames never run, so any libgit2 handles
///   `body` allocated leak. This is the accepted trade-off: the alternative is a
///   hard process crash, and the fault is rare. No Swift runtime invariant is
///   corrupted — the only consequence is leaked retains/handles. `run`'s own
///   frame is *not* abandoned: the `siglongjmp` returns into
///   `casper_run_sigbus_guarded`, which returns normally into `run`.
enum SigbusGuard {
    /// Runs `body` under a SIGBUS guard. Returns its value or rethrows its error
    /// on the normal path. If a SIGBUS is caught while `body` runs, throws a
    /// `GitError` matching libgit2's own "file changed before we could read it"
    /// race so callers handle it through their existing graceful path.
    ///
    /// `body` is `@escaping` on purpose: `withoutActuallyEscaping` cannot be used
    /// here because its end-of-scope uniqueness check traps precisely on the fault
    /// path — the abandoned frames leak a retain on `body`, which the check reads
    /// as an illegal escape. That leaked retain is exactly the accepted trade-off
    /// documented above, so we take an escaping closure and let it leak silently
    /// on the rare fault instead of turning the fault into a hard trap.
    static func run<T>(_ body: @escaping () throws -> T) throws -> T {
        // Holds `body`'s outcome. Captured by `thunk`, so it is heap-boxed and
        // readable after a caught fault (it stays `nil` in that case, since `body`
        // never completed).
        var outcome: Result<T, Error>?

        // Standard C-callback trampoline: stash a thunk in a local and hand its
        // address to C as the opaque context. The C-compatible callback casts it
        // back and invokes it, so no Swift closure context crosses the C boundary
        // as a closure — only as an opaque pointer.
        var thunk: () -> Void = {
            outcome = Result { try body() }
        }
        let caughtSigbus = withUnsafeMutablePointer(to: &thunk) { thunkPointer in
            casper_run_sigbus_guarded({ context in
                context!.assumingMemoryBound(to: (() -> Void).self).pointee()
            }, thunkPointer)
        }

        if caughtSigbus != 0 {
            throw GitError(
                code: -1,
                message: "file changed before we could read it (SIGBUS guarded)")
        }

        // `body` ran to completion, so the outcome is always populated here.
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw GitError(code: -1, message: "SIGBUS guard produced no result")
        }
    }
}
