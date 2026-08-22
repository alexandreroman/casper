---
name: "Main-thread hang watchdog and dump exploitation"
description: "How UI-freeze sample dumps are produced in dev builds, and how to capture and read one on a release build"
type: project
---

# Main-thread hang watchdog and dump exploitation

Casper intermittently beachballs (spinning wheel, main thread blocked), with no
reliable reproduction yet. `MainThreadHangWatchdog`
(`Sources/CasperCore/MainThreadHangWatchdog.swift`, wired in
`CasperUI/AppDelegate.swift`) is temporary diagnostic scaffolding that catches
it: a background timer detects the main thread staying unresponsive past a
threshold (default 2 s) and runs `/usr/bin/sample` against Casper's own pid, so
the resulting stack dump shows what the main thread is blocked on. The whole
file and its wiring sit behind `#if DEBUG`, so the shipped app carries none of
it. The scaffolding is deliberately temporary: it comes out entirely once the
hang is root-caused **and** the fix is confirmed live (which takes a live
session — see [[diff-view-refresh-hang]]).

**Why:** a freeze is not a crash — the process stays alive, so macOS writes **no
crash report**, and the published dSYM (see [[binary-size-budget]]) covers real
crashes rather than freezes. The only way to learn where the main thread is
stuck is a live `sample`/`spindump` while it is hung, or the retrospective
unified log. Automating that is worth its weight while iterating locally; on a
distributed build the same capture is a one-line manual command, which is why
the shipped binary carries no permanent 500 ms timer. Sibling instrumentation to
the diff SIGBUS guard (see [[sigbus-guard-diff]], which *does* ship in release);
the earlier fixed UI freeze is [[diff-view-refresh-hang]]. If captured samples
repeatedly point at the diff/libgit2 path (`computeDiff` / `diffWorkdirToHead`),
start there.

The liveness probe rides the **main run loop** (`CFRunLoopPerformBlock`), not
the main dispatch queue, or every modal alert reads as a hang — see
[[main-queue-starved-by-modal-loops]] for the mechanism and the accepted
trade-off.

**How to access after a freeze:**

- **Manual capture, works on any build including the distributed one:** from an
  **external** terminal — Casper's own embedded terminals freeze with the app —
  run `sample $(pgrep -x casper) 10 -file /tmp/casper-hang.txt`, or the fuller
  `/tmp/casper-hang-dump.sh` recipe (sample + `lldb bt all` + spindump + log).
  This works without root because the release build is ad-hoc signed with **no
  hardened runtime**. The archived diff-hang dumps
  `~/Library/Logs/Casper/hang-20260730-manual-{A,B}.txt` come from exactly this
  recipe — `sample $(pgrep -x casper) 3 -file …` against a **release** build,
  which auto-captures nothing since the watchdog is DEBUG-only. A 3 s sample is
  enough for a spin: the main thread is busy, not waiting, so every sample lands
  in the loop.
- **Auto-captured dumps (dev builds, `make dev`):**
  `~/Library/Logs/Casper/hang-<yyyyMMdd-HHmmss>.txt`. Read the main thread
  (Thread 0) call tree — that is where the block is. A macOS notification
  "Casper UI freeze captured" fires on success.
- **Log marker (dev builds, written even if `sample` fails):** `.fault` under
  subsystem `com.github.alexandreroman.casper`, category `app`, text
  "main-thread hang detected …". Read it back with:

  ```bash
  log show --predicate 'subsystem == "com.github.alexandreroman.casper"' \
    --last 30m --info --debug
  ```

- **Tuning (dev builds, no rebuild):** `CASPER_HANG_THRESHOLD=<seconds>`
  overrides the 2 s threshold; `CASPER_HANG_WATCHDOG=0` disables it entirely.
