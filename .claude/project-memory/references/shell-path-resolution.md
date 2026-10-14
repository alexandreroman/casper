---
name: "Shell PATH resolution"
description: "Casper probes the shell for PATH with every rung on each cold probe, against a monotonic deadline"
type: project
---

# Shell PATH resolution

`LoginShellPath` probes the user's shell for its **`PATH`** and resolves command
names against it in Swift. The mechanism — the unioned `-i -l -c` / `-i -c` /
`-l -c` / `-c` rungs, the `/usr/bin/printenv PATH` body, stdin on `/dev/null`,
the banner-safe ordering, the 5 s bound and the process-lifetime cache — is in
`.superpowers/themes/cli-agents.md`, next to the agent-integration probe,
together with why the shell is never asked to resolve a command. Two rules sit
outside it.

**No rung is ever trimmed.** All three rungs run on every cold probe. Dropping
the `-i -c` rung takes the cold probe from ~0.5 s to ~0.3 s, and a login-only
probe costs ~0.1 s, but each cut buys speed by making the lookup wrong again —
first for every bash user whose `PATH` lives in `.bashrc`, then for everyone.
The cost is paid once per process, off the main actor, and is flat in the
number of command names, so it stays a launch cost and never a per-lookup one.

**The deadline is monotonic.** It is a `DispatchTime`, passed down to each spawn
as a parameter rather than parked in shared state, and compared against
`DispatchTime.now()` in both the rung guard and the terminate-watchdog. A
`Date` deadline would jump across a system sleep and skip every rung while the
monotonic budget the waiting semaphore uses had barely moved.

**Why:** a GUI app launched from Finder inherits the bare launchd `PATH`, so
agent CLIs and editor shims are invisible without asking the shell — and
asking it the wrong question yields a confident wrong answer, not a miss.

**How to apply:** keep every command lookup going through
`LoginShellPath.resolve`, and treat a suggestion to shell out to
`which`/`command -v`, or to drop a rung for speed, as a regression. See
[[agent-integration-policy]] for what that cold cost buys.
