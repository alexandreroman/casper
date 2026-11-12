---
name: "Foreground-process identification facts"
description: "How to re-measure the agents' process shapes, and the real-PTY test traps: copied binaries die, the shell's group settles late"
type: reference
---

# Foreground-process identification facts

The classifier in `Sources/CasperCore/ForegroundProcess.swift` rests on facts
measured outside the repository, on macOS, with a libproc probe and a PTY
harness: native Claude Code's `p_comm` is its version string, `/usr/bin/login`
leads the PTY session, npm installs run native `*.exe` binaries, `codex.js`
`execve`s into the native binary. The facts themselves are recorded in
`.superpowers/themes/agent-state-detection.md` § Foreground-process
identification; this note holds how to re-measure them and the traps of
testing against a real PTY.

**Testing against a real PTY:**

- A **copied** platform binary (`cp /bin/sleep claude`) is SIGKILLed at
  launch. A **symbolic link** named `claude` to `/bin/sleep` runs, and its
  argv[0] and exec path name `claude`, the same path native Claude Code takes.
- At the real-surface harness's fixed `settle(0.6)`
  ([[ghostty-real-surface-e2e-harness]]) the shell's group can still hold a
  zsh startup helper, which reads `.other`; a foreground test settles an extra
  second first.

**Why:** each measured fact rules out a simpler design that looks right, and
each can drift with an agent's installer: `proc_name` alone misses native
Claude Code, "pgid == sid" never matches the shell, a `node` check misses the
npm installs. A test that copies a binary fails for a reason unrelated to the
code under test.

**How to access:** re-measure after an agent's installer changes with
`ps -o pid,pgid,tpgid,comm,args -t <tty>` from a second terminal (`tpgid` is
the foreground group; `comm` there is argv[0], not the kernel's `p_comm`) and
a small libproc program calling `proc_name`, `proc_pidpath`,
`proc_pidinfo(PROC_PIDTBSDINFO)` and `sysctl` `KERN_PROCARGS2`. Start the
agent under a real PTY (Python `pty.fork`) to see its group shape. In the
running app, `casper debug dump-state` reports each surface's
`foregroundProcess`. Casper reads processes and writes no agent
configuration, per [[agent-integration-policy]]; Codex's own install quirks
are in [[codex-detection-caveats]].
