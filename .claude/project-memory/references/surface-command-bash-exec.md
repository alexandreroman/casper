---
name: "Surface command execution runs via a hardcoded bash exec, not the user's shell"
description: "ghostty_surface_config_s.command is not inert — it execs through bash regardless of $SHELL, so zsh-only PATH (Homebrew, mise) is unavailable to it"
type: project
---

**Fixed** — `--command` now runs via `initial_input` (typed into the real
login shell, no `exec`), not the broken `bash -l -c "exec"` path described
below. See `.superpowers/sdd/2026-07-09-terminal-command-initial-input-design.md`
for the fix design. The root-cause analysis below remains accurate history.

# Surface command execution runs via a hardcoded bash exec, not the user's shell

`GhosttySurfaceConfiguration.command` (set from `terminal new --command` /
`workspace new --command`) is **not inert**, correcting the prior belief
recorded in `architecture.md`/`status.md`/`cli-agents.md`. It reaches
`ghostty_surface_config_s.command` and does execute — but the pinned
`libghostty-spm` (host-managed) fork always runs it as `bash -l -c "exec
<command>"`, regardless of the user's configured login shell. Confirmed live:
launching a surface with `command = "echo INVOKER=$0 SHELL=$SHELL"` printed
`INVOKER=bash SHELL=/bin/zsh` — `$SHELL` is correctly inherited/set, but the
interpreter actually running the command is bash. The `exec` semantics also
mean the command **replaces** the shell process (confirmed: a compound `a ;
b ; c` command only ran `a`, because `exec a` never returns to run `b`/`c`).

**Why:** the user's Homebrew (`/opt/homebrew/bin`, where `uv` and other tools
live) and mise-managed toolchains are added to `PATH` only by `~/.zprofile`/
`~/.zshrc` (zsh-specific) — never by `~/.bash_profile`/`~/.bashrc`. Any
`--command` that depends on those `PATH` entries fails with `bash: line 0:
exec: <cmd>: not found`, even though the exact same command works fine typed
into a normal (commandless) Casper terminal, because that one launches the
user's real login shell (zsh here) directly, which re-sources its own
profile and rebuilds `PATH` regardless of what the surface's env carries.

**How to apply:** don't trust `--command`/`workspace new --command` for
anything that isn't on the *minimal* `bash -l` PATH. When investigating
"my command wasn't found" reports for a Casper-launched terminal, check
which shell actually ran it before assuming a Casper PATH-injection bug —
`ClaudeCodeAdapter.surfaceEnvironment` only injects `CASPER_*` vars, `PATH`
(rebuilt from the app's own inherited `PATH`, no zsh dotfiles), never
`SHELL`/`HOME`. This also reopens the previously-closed "agent-as-command
surface" design question in `agent-state-detection.md` (deferred child-exit
lifecycle work) — since `command` really does replace the shell process via
`exec`, a directly-observable agent process may be viable after all, via a
different mechanism than the vendored fork's own (broken) `command` field —
see [[surface-shell-command-execution-fix]] for the fix design once written.
