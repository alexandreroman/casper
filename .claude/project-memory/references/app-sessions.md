---
name: "App sessions (--session)"
description: "casper --session <name> (DEBUG builds only) suffixes layout+sockets and sets CASPER_SESSION; live-verify the GUI under session dev to never disturb the real instance"
type: feedback
---

# App sessions (--session)

When live-verifying the Casper GUI during development (the `debug-casper` skill,
or any manual launch), **always run under a dedicated session**:
`Casper-dev.app/Contents/MacOS/casper --session dev`, with
`export CASPER_SESSION=dev` for the debug CLI that talks to it. Launch the
bundle's executable rather than `.build/debug/casper` directly — the app bundle
is what carries the code signature the Screen Recording grant is attached to
(see [[tcc-screen-recording-needs-a-bundle]]). A session isolates the debug
socket (`/tmp/casper-debug-dev.sock`), control socket
(`$TMPDIR/casper-control-dev.sock`), and layout file (`session-dev.json`) from
the user's real instance, so verification never clobbers their saved layout or
hijacks their sockets.

**Why:** an unnamed instance and a dogfooded real one both bind the same fixed
paths (`casper-control.sock`, `/tmp/casper-debug.sock`, `session.json`); the
second one rewrites the real `session.json` on quit and unlinks the live socket.
A named session removes that collision — a `--session dev` run leaves the real
`session.json` untouched. `make dev` needs no argument of its own: it
derives `DEV_SESSION` from the current branch name, sanitized to
`SessionIdentity`'s charset, so two worktrees on different branches already get
independent sessions. A hand-rolled launch is the case that has to name one.

**How to apply:**

- `SessionIdentity` (CasperCore) is the single source of the `-<name>` suffix,
  and only a debug build parses `--session` (`.superpowers/themes/core.md`
  § SessionStore). Name rule: 1–32 chars from `[A-Za-z0-9._-]`; an invalid name
  exits non-zero at launch in a debug build (never a silent fallback).
- Neither CLI takes a `--session` flag: the domain CLI follows the
  `CASPER_CONTROL_SOCKET` injected into the terminal, and the debug CLI derives
  its socket from `CASPER_SESSION` — see `.superpowers/themes/cli-agents.md`
  § Agent state & progress and `.superpowers/themes/debug.md`.
- Two instances can still draw the same port block: the randomized scan start
  only reduces that (`.superpowers/themes/core.md` § PortAllocator).
