---
name: "Socket listen-path vs dial-path resolution"
description: "A listener binds to the session-derived socket path only; the CASPER_*_SOCKET env override is dial-side, or a listener hijacks another instance's socket"
type: project
---

# Socket listen-path vs dial-path resolution

Casper's two channels both distinguish **bind-side** from **dial-side** path
resolution, and mixing them up causes a real cross-instance socket hijack. The
two channels express the split differently:

- **Control channel** — `SessionIdentity.controlSocketPath()` (CasperCore) is
  bind-side and reads no environment variable at all. The
  `CASPER_CONTROL_SOCKET` override lives purely on the dial side, in
  `CasperCLI/ControlClient.swift`, which reads it directly when sending a
  command. `AppDelegate` binds its `ControlServer` to
  `controlSocketPath()`.
- **Debug channel** (`DebugSocketPath`, DEBUG-only) — `resolve(for:)` and
  `.default` are dial-side: the `CASPER_DEBUG_SOCKET` override wins, else the
  session-derived path (the external `casper debug` CLI's `SocketOption.path`
  is the live caller). `listenPath(for:)` is bind-side: always
  `session.debugSocketPath`, unconditionally ignoring the env var.
  `AppDelegate` binds its `DebugServer` via `listenPath(for:)`.

**Why:** every terminal a running Casper.app opens unconditionally carries that
instance's own `CASPER_CONTROL_SOCKET` (`AgentEnvironment.swift`, regardless of
session — see [[domain-cli-control-channel]]). If a listener resolved its bind
path through the env override, launching a second, differently `--session`-named
instance (e.g. via the `debug-casper` harness, see [[app-sessions]]) **from
inside a terminal the real instance opened** would make the new instance inherit
the real instance's socket path; its `start()` would then `unlink()` and rebind
onto the REAL instance's socket, silently hijacking it even though `--session`
was passed correctly. Session-derived bind paths avoid this: the second instance
binds its own socket and the first instance's socket file stays untouched.

**How to apply:**

- Decide a listener's own bind path from the `SessionIdentity` alone. Honor a
  `CASPER_*_SOCKET` env var only from a CLI/dial context, which has no
  `SessionIdentity` of its own to fall back to.
- Any new bind site (a second app entry point, a preview target, etc.) must use
  `SessionIdentity.controlSocketPath()` or `DebugSocketPath.listenPath(for:)`.
- `SessionIdentity.controlSocketPath()`/`.debugSocketPath` read no env var, so
  the disambiguation is purely the `--session` name — safe as long as callers
  pick the bind-side resolver.
- `SocketPathResolutionTests` pins both halves: that a listen path is
  session-derived, and that it ignores an ambient env override.
- See [[app-sessions]] and [[domain-cli-control-channel]] for the surrounding
  session/env-injection design.
