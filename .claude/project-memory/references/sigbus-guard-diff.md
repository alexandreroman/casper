---
name: "SIGBUS guard around libgit2 diff"
description: "In-process SIGBUS handler funnels mmap-truncation faults during libgit2 diff/status/checkout into a graceful throw"
type: project
---

# SIGBUS guard around libgit2 diff

libgit2 `mmap`s working-directory files to diff them. A background coding agent
truncating a worktree file after libgit2 maps it but before xdiff
(`xdl_hash_record`) reads the mapped pages raises a hardware `SIGBUS`
(`KERN_MEMORY_ERROR`) that no Swift `do`/`catch` can catch, killing the process.
libgit2 installs no SIGBUS handler of its own.

The fix is an in-process SIGBUS guard — the established
`sigsetjmp`/signal-handler technique for recovering from a `SIGBUS` on a
truncated `mmap` — around the three libgit2 calls that read mapped
working-directory files: the working-tree diff and the `isClean` status walk
(`Repository.swift`) and `forceCheckoutHead` (`Merge.swift`). The mechanism —
SIGBUS only, the `_Thread_local` jump buffer, the `SIG_DFL` re-fault outside a
guarded region — is in `.superpowers/themes/git-worktrees.md` § Design. On a
caught fault `SigbusGuard.run` throws `GitError(code: -1, message: "file changed
before we could read it (SIGBUS guarded)")`, matching libgit2's own stat-race
message so it lands on the existing graceful `computeDiff` catch (log + return
nil, refresh next revision).

Accepted trade-off: on the fault path `siglongjmp` abandons the frames inside
`body`, so Swift `defer`/ARC cleanup there never runs and any libgit2 handles
`body` allocated leak. No Swift runtime invariant is corrupted (only leaked
retains). The path is rare.

## Gotcha: `body` must be `@escaping`, NOT `withoutActuallyEscaping`

`SigbusGuard.run` takes `@escaping () throws -> T`. Do **not** try to keep it
non-escaping via `withoutActuallyEscaping`: that helper's end-of-scope
uniqueness check traps (`closure argument was escaped`) precisely on the fault
path, because the abandoned frames leak a retain on the closure — the check
reads that leaked retain as an illegal escape and turns the recoverable fault
into a hard crash, defeating the guard. Taking an escaping closure lets the
retain leak silently on the rare fault instead. Because the closure is escaping,
callers inside `Repository` need an explicit `[self]` capture list.

## Test

`Tests/CasperGitTests/SigbusGuardTests.swift` proves it deterministically:
`mmap` one page of a temp file, `ftruncate` it to 0, then read the now-unbacked
page inside `SigbusGuard.run` (real SIGBUS on Darwin) and assert `run` throws
rather than crashing. The faulting read stores into a module-level
`nonisolated(unsafe)` sink the test reads back, so the load is not optimized
away (a discarded `_ = ptr[0]` read gets elided and never faults). A follow-up
guarded `run` must still work, proving the thread-local jump state is restored.
