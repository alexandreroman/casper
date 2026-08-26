#include "csigbus_guard.h"

#include <pthread.h>
#include <setjmp.h>
#include <signal.h>

// The jump buffer for the region currently guarded on THIS thread, or NULL when
// no guard is active. Thread-local because concurrent diffs run on several
// cooperative-pool threads, and the SIGBUS handler executes on the faulting
// thread: it must jump into that thread's own buffer, not another's.
static _Thread_local sigjmp_buf *casper_guarded_env = NULL;

// The signal handler runs on the faulting thread. If that thread is inside a
// guarded region, unwind to it; the fault becomes a non-zero return from
// casper_run_sigbus_guarded. Otherwise the SIGBUS is unrelated to any guard, so
// restore the default disposition and return: the faulting instruction
// re-executes and produces a genuine crash report (crash fidelity preserved).
static void casper_sigbus_handler(int signal_number) {
    if (casper_guarded_env != NULL) {
        siglongjmp(*casper_guarded_env, 1);
    }
    signal(signal_number, SIG_DFL);
}

static pthread_once_t casper_install_once = PTHREAD_ONCE_INIT;

// Two known limitations, both acceptable for the one guarded region this serves
// (libgit2 diff): the previous disposition is discarded rather than chained, so a
// SIGBUS handler another library installed first stops running; and sa_flags omits
// SA_ONSTACK, so a SIGBUS raised on an exhausted stack has no alternate stack to
// run the handler on.
static void casper_install_handler(void) {
    struct sigaction action;
    action.sa_handler = casper_sigbus_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGBUS, &action, NULL);
}

int casper_run_sigbus_guarded(void (*body)(void *ctx), void *ctx) {
    pthread_once(&casper_install_once, casper_install_handler);

    // Save the enclosing guard so nested/reentrant calls restore it on the way
    // out rather than clearing the guard entirely.
    sigjmp_buf *previous_env = casper_guarded_env;

    sigjmp_buf env;
    int rc = 0;
    // savesigs = 1: after a longjmp out of the handler the signal mask is
    // restored, so SIGBUS is not left blocked.
    if (sigsetjmp(env, 1) == 0) {
        casper_guarded_env = &env;
        body(ctx);
    } else {
        rc = 1;
    }

    casper_guarded_env = previous_env;
    return rc;
}
