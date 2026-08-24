---
name: "Shell PATH resolution"
description: "Casper asks the shell for PATH and searches it itself; a shell must never be asked to resolve a command"
type: project
---

# Shell PATH resolution

`LoginShellPath` finds a command by probing the user's shell for its **`PATH`**
and then searching that path in Swift, taking the first **regular file** that is
also executable. `FileManager.isExecutableFile(atPath:)` alone is not enough: it
is `access(X_OK)`, which answers true for any searchable directory, so a
`fileExists(atPath:isDirectory:)` check goes beside it. Two rules hold it
together.

## The shell is never asked to resolve a command

`which` and `command -v` are off limits, whatever the flags. An interactive
shell defines the user's aliases and **functions**, and both tools report them:
a `.zshrc` that declares a `codex` function makes `zsh -ilc 'which codex'` print
a multi-line function body and `zsh -ilc 'command -v codex'` print the bare word
`codex`. Neither is a path, and a "last non-empty line" reading of either
returns a closing brace. Only the filesystem decides what exists.

## The probe must be interactive, and login is not enough

`$SHELL -lc` is a login **non-interactive** shell: zsh sources `.zshenv`,
`.zprofile`, `.zlogin` and never `.zshrc`. bash's split is not the mirror image
of that one: bash reads `~/.bashrc` **only** for an interactive *non-login*
shell, so an interactive login bash reads `~/.bash_profile` and stops, and
`-i -l -c` returns exactly what `-l -c` returns for every bash user.

The `PATH` a user actually has in a terminal is commonly built in an rc file, so
three rungs are tried and **unioned**, in this order:

1. `-i -l -c` — reaches zsh's `.zshrc`.
2. `-i -c` — the only rung that reaches bash's `.bashrc`; zsh sources `.zshrc`
   here too.
3. `-l -c` — neither rc file, but every shell accepts it.

All three run on every cold probe. That is a deliberate trade: dropping the
`-i -c` rung takes the cold probe from ~0.5 s to ~0.3 s, and a login-only probe
costs ~0.1 s, but each cut buys speed by making the lookup wrong again — first
for every bash user whose `PATH` lives in `.bashrc`, then for everyone. The cost
is paid once per process, off the main actor, and is flat in the number of
command names, so it stays a launch cost and never a per-lookup one.

`-c` alone is the last rung, reached only when all three produced nothing, for
`/bin/csh` and `/bin/tcsh`, which reject `-l` with `Unknown option: '-l'`.

The union means no rung's answer can be **shrunk** by another — not that
resolution never returns less than a single login shell would, since a probe
that never completes contributes only what its finished rungs found. `-i` also
buys rc-file side effects a profile would not have: an `exec tmux` guarded on
`$TMUX` makes that rung contribute nothing at all.

Other invariants of the probe:

- The body is the single command `/usr/bin/printenv PATH` — absolute, free of
  shell syntax, so it is dialect-independent (fish's `$PATH` is a list; csh has
  no `export`), because `PATH` reaches every child as an environment variable.
- Every spawn sets `standardInput` to `FileHandle.nullDevice`. A profile that
  reads stdin blocks forever when the child inherits the app's input, and gets
  EOF at once against `/dev/null`.
- The output parse keeps only `/`-prefixed components, and **orders** the real
  `PATH` line — the last line whose `:`-separated components are all absolute —
  ahead of what every other line contributed. A profile prints its banners
  before `printenv` runs, so without that ordering a directory named in a
  banner would outrank the whole real `PATH` and decide the answer whenever
  two directories hold the same command.
- The deadline is a **monotonic** `DispatchTime`, passed down to each spawn as a
  parameter rather than parked in shared state, and compared against
  `DispatchTime.now()` in both the rung guard and the terminate-watchdog. A
  `Date` deadline would jump across a system sleep and skip every rung while the
  monotonic budget the waiting semaphore uses had barely moved.
- One probe per process (up to three spawns, ~0.5 s cold) serves every command
  name, and the 5 s bound covers the probe as a whole. Rungs publish their
  components as they finish, so a timeout keeps what already answered; the
  result is then cached **for the process's whole life**, timed out or not, so
  an abandoned probe leaves the bare launchd `PATH` in place until relaunch.

**Why:** a GUI app launched from Finder inherits the bare launchd `PATH`, so
agent CLIs and editor shims are invisible without asking the shell — and
asking it the wrong question yields a confident wrong answer, not a miss.

**How to apply:** keep every command lookup going through
`LoginShellPath.resolve`, and treat a suggestion to shell out to
`which`/`command -v` as a regression. See
[[agent-integration-probe-cadence]] for what pays that cold cost.
