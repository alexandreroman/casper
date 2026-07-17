---
name: "Main-thread hang watchdog and dump exploitation"
description: "How auto-captured UI-freeze sample dumps are produced and how to read them after a beachball"
type: project
---

# Main-thread hang watchdog and dump exploitation

Casper intermittently beachballs (spinning wheel, main thread blocked) on real
release builds, with no reliable reproduction yet. `MainThreadHangWatchdog`
(`Sources/CasperCore/MainThreadHangWatchdog.swift`, wired in
`CasperUI/AppDelegate.swift`) is temporary diagnostic scaffolding that catches
it: a background timer detects the main thread staying unresponsive past a
threshold (default 2 s) and runs `/usr/bin/sample` against Casper's own pid, so
the resulting stack dump shows what the main thread is blocked on. It ships in
**release too** (no `#if DEBUG`) on purpose, and must be reverted once the hang
is root-caused.

**Why:** a freeze is not a crash — the process stays alive, so macOS writes **no
crash report**. The only way to learn where the main thread is stuck is a live
`sample`/`spindump` while it is hung, or the retrospective unified log. The
release build is ad-hoc signed with **no hardened runtime**, so `sample` on the
own pid works in the field without root. Sibling instrumentation to the diff
SIGBUS guard (see `sigbus-guard-diff`); the earlier fixed UI freeze is
`diff-view-refresh-hang`. If captured samples repeatedly point at the
diff/libgit2 path (`computeDiff` / `diffWorkdirToHead`), start there.

**How to access after a freeze:**

- **Auto-captured dumps:** `~/Library/Logs/Casper/hang-<yyyyMMdd-HHmmss>.txt`.
  Read the main thread (Thread 0) call tree — that is where the block is.
- **Log marker (always written, even if `sample` fails):** `.fault` under
  subsystem `com.github.alexandreroman.casper`, category `app`, text
  "main-thread hang detected …". A macOS notification "Casper UI freeze
  captured" fires on success.
  `log show --predicate 'subsystem == "com.github.alexandreroman.casper"' --last 30m --info --debug`
- **Tuning (no rebuild):** `CASPER_HANG_THRESHOLD=<seconds>` overrides the 2 s
  threshold; `CASPER_HANG_WATCHDOG=0` disables it entirely.
- **Manual capture (any build):** from an **external** terminal — Casper's own
  embedded terminals freeze with the app — run
  `sample $(pgrep -x casper) 10 -file /tmp/casper-hang.txt`, or the fuller
  `/tmp/casper-hang-dump.sh` recipe (sample + `lldb bt all` + spindump + log).
