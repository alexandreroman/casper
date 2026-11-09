---
name: "Foreground-process identification facts"
description: "Measured macOS/PTY facts agent identification rests on: native Claude's p_comm is its version, login leads the session, npm .exe binaries"
type: reference
---

# Foreground-process identification facts

Facts about how the three agents and the shell look from the kernel's process
table inside a Casper terminal, measured on macOS (2026-11-09) with a libproc
probe and a PTY harness. None is derivable from this repository; the classifier
in `Sources/CasperCore/ForegroundProcess.swift` and
`.superpowers/themes/agent-state-detection.md` § Foreground-process
identification are built on them.

**Native Claude Code is named by argv, never by its process name.** Its
installer links `~/.local/bin/claude` to a versioned file
(`~/.local/share/claude/versions/<version>`), so the kernel's `p_comm`
(`pbi_comm`, `proc_name`) and the `proc_pidpath` basename are the version
string (`2.1.319`). Only `KERN_PROCARGS2` names it: the exec path as invoked
(`~/.local/bin/claude`) and argv[0] (`claude`). `ps -o comm` shows `claude`
because it prints argv[0], which makes the trap easy to miss.

**`/usr/bin/login` leads the PTY session, not the shell.** The pinned
libghostty spawns the shell the upstream macOS way (`login -flp … <shell>`).
`login` runs as root, so its arguments are unreadable; the shell is its child,
in a process group of its own, and `getsid` of every process on the PTY is
login's PID. "Foreground group == session" therefore never identifies the
shell.

**npm installs of Claude Code and opencode run the native binary.**
`@anthropic-ai/claude-code` and `opencode-ai` ship a `bin/*.exe` placeholder
that their postinstall hard-links (or copies) the platform binary over: the
process is native, named `claude.exe` / `opencode.exe` on disk, with argv[0]
`claude` / `opencode`.

**`@openai/codex` has two shapes.** Its `bin/codex.js` calls `process.execve`
into the native binary when Node provides it: same PID, the image becomes
`…/codex`, so `comm` changes under an unchanged PID. On a Node without it, it
spawns the binary as a child and `node …/@openai/codex/bin/codex.js` stays the
group leader; argv[1] is then the only thing naming Codex.

**An interactive shell at its prompt is alone in its group**
(`proc_listpgrppids` → 1); its helpers such as `gitstatusd` sit in other
groups. Two exceptions: a prompt's `$(…)` command substitutions run in the
shell's own group for an instant, and a non-interactive shell (a script) does
no job control, so the commands it runs share its group.

**libproc and Swift interop gotchas:**

- `proc_listpgrppids(pgid, buffer, size)` returns a **count of PIDs** when
  given a buffer. Given `NULL` it returns a system-wide estimate, never the
  group's size, so a real buffer is always passed.
- `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift does not import; its value is
  `4 * MAXPATHLEN`.
- Measured costs: `proc_pidinfo(PROC_PIDTBSDINFO)` ≈ 0.75 µs,
  `proc_listpgrppids` ≈ 24 µs.

**Testing against a real PTY:**

- A **copied** platform binary (`cp /bin/sleep claude`) is SIGKILLed at
  launch. A **symbolic link** named `claude` to `/bin/sleep` runs, and its
  argv[0] and exec path name `claude`, the same path native Claude Code takes.
- At the real-surface harness's fixed `settle(0.6)`
  ([[ghostty-real-surface-e2e-harness]]) the shell's group can still hold a
  zsh startup helper, which reads `.other`; a foreground test settles an extra
  second first.

**Why:** each fact rules out a simpler design that looks right: `proc_name`
alone misses native Claude Code, "pgid == sid" never matches the shell, a
`node` check misses the npm installs, and a group count without the
prompt-`$(…)` exception swallows an agent's exit edge.

**How to access:** re-measure after an agent's installer changes with
`ps -o pid,pgid,tpgid,comm,args -t <tty>` from a second terminal (`tpgid` is
the foreground group; `comm` there is argv[0]) and a small libproc program
calling `proc_name`, `proc_pidpath` and `sysctl` `KERN_PROCARGS2`. In the
running app, `casper debug dump-state` reports each surface's
`foregroundProcess`. Casper reads processes and writes no agent configuration,
per [[agent-integration-policy]]; Codex's own install quirks are in
[[codex-detection-caveats]].
