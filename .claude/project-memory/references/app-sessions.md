---
name: "App sessions (--session) and isolated live verification"
description: "casper --session <name> suffixes layout+sockets and sets CASPER_SESSION; live-verify the GUI under session dev to never disturb the real instance"
type: feedback
---

# App sessions (--session) and isolated live verification

When live-verifying the Casper GUI during development (the `debug-casper` skill,
or any manual run of `.build/debug/casper`), **always launch under a dedicated
session**: `.build/debug/casper --session dev` and `export CASPER_SESSION=dev`.
This isolates the debug socket (`/tmp/casper-debug-dev.sock`), control socket
(`$TMPDIR/casper-control-dev.sock`), and layout file (`session-dev.json`) from
the user's real instance, so verification never clobbers their saved layout or
hijacks their sockets.

**Why:** `make dev`/`.build/debug/casper` and a dogfooded real instance both
otherwise bind the same fixed paths (`casper-control.sock`,
`/tmp/casper-debug.sock`, `session.json`); a second unnamed instance rewrites the
real `session.json` on quit and unlinks the live socket. A named session removes
that collision. Confirmed by live test: a `--session dev` run left the real
7 KB `session.json` untouched.

**How to apply:**

- `SessionIdentity` (CasperCore) is the single source of the `-<name>` suffix.
  No `--session` → default session = byte-for-byte the historical paths (no
  `CASPER_SESSION` injected). Name rule: 1–32 chars from `[A-Za-z0-9._-]`; an
  invalid name exits non-zero at launch (never a silent fallback).
- **Domain CLI** (`status`/`notify`/…) needs no change per session: it reads the
  per-session `CASPER_CONTROL_SOCKET` already injected into the terminal — it
  does **not** read `CASPER_SESSION`. Keep the "only works inside a Casper
  terminal" invariant.
- **Debug CLI** (external) derives its socket from `CASPER_SESSION`
  (`CASPER_DEBUG_SOCKET` full-path override still wins); there is no `--session`
  CLI flag.
- Ports: `PortAllocator` uses a randomized scan start (`randomStartBase`) to
  reduce — not eliminate — cross-instance port-block collisions.
- See [[domain-cli-control-channel]] and the design spec
  `.superpowers/sdd/2026-07-06-app-session-{design,plan}.md`.
