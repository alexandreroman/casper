#ifndef CASPER_CSIGBUS_GUARD_H
#define CASPER_CSIGBUS_GUARD_H

/// Runs body(ctx) on the current thread with a SIGBUS guard active.
///
/// Returns 0 if body ran to completion; non-zero if a SIGBUS was caught while
/// body was executing (body was aborted mid-execution via siglongjmp, so any
/// cleanup that had not yet run inside body will never run).
///
/// The guard covers SIGBUS only. SIGSEGV is intentionally left alone so genuine
/// memory-safety bugs still crash. Guarded regions may nest and may run
/// concurrently on multiple threads.
int casper_run_sigbus_guarded(void (*body)(void *ctx), void *ctx);

#endif /* CASPER_CSIGBUS_GUARD_H */
