---
name: "Throwaway GUI probe cleanup"
description: "A /tmp SwiftUI/AppKit probe app is killed by its captured PID inside a trap, then confirmed gone with pgrep"
type: feedback
---

# Throwaway GUI probe cleanup

A throwaway GUI app built in `/tmp` to check AppKit or menu-bar behavior is
launched with its PID captured (`./probe & pid=$!`) or by absolute path. It is
killed by that PID from a `trap`, so cleanup runs even when a wait loop times
out or a step fails. `pgrep -fl` then confirms it is gone before anyone reports
the probe as deleted.

**Why:** `pkill -f /tmp/dir/probe` does not match a process started as
`./probe`, because its command line holds the relative path. Two leaked probes
spun at 100% CPU for about 50 minutes (2026-10-15) until a teammate killed them.

**How to apply:** use this for every app launched during verification, dev
sessions included (`casper --session test-…`). Never kill the user's own
`--session` instance.
