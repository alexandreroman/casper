---
name: "Socket listen-path vs dial-path resolution"
description: "The App must bind its own control/debug socket via listenPath(for:), never resolve(for:)/.default, or it hijacks a differently-sessioned running instance's socket"
type: project
---

# Socket listen-path vs dial-path resolution

`ControlSocketPath` and `DebugSocketPath` (CasperCore) expose two distinct kinds
of path resolution, and mixing them up reintroduces a real cross-instance
socket hijack:

- `resolve(for:)` / `.default` — **dial-side**: `CASPER_CONTROL_SOCKET` /
  `CASPER_DEBUG_SOCKET` env override wins, else the session-derived path. For a
  CLI that wants to reach whatever socket its terminal is wired to (the
  external `casper debug` CLI's `SocketOption.path` is the one live caller).
- `listenPath(for:)` — **bind-side**: always `session.controlSocketPath()` /
  `session.debugSocketPath`, unconditionally ignoring the env var. `AppDelegate`
  must use this — and only this — to decide where its own `ControlServer` /
  `DebugServer` binds.

**Why:** every terminal a running Casper.app opens unconditionally carries that
instance's own `CASPER_CONTROL_SOCKET` (`ClaudeCodeAdapter.swift`, regardless of
session — see [[domain-cli-control-channel]]). `AppDelegate` used to call
`resolve(for:)` for its own bind path, so launching a second, differently
`--session`-named instance (e.g. via the `debug-casper` harness, see
[[app-sessions]]) **from inside a terminal the real instance opened** made the
new instance inherit the real instance's `CASPER_CONTROL_SOCKET`; its
`ControlSocketServer.start()` then `unlink()`ed and rebound onto the REAL
instance's socket, silently hijacking it even though `--session` was passed
correctly. Confirmed both by code reading and by a live repro: instance A
(session `sim-main`) launched, a terminal-inherited env exported A's real
control-socket path, instance B launched with `--session sim-dev` inheriting
that env — post-fix, B bound its own session-derived socket and A's socket
file's inode/mtime never changed.

**How to apply:**

- Never call `resolve(for:)`/`.default` to decide a listener's own bind path —
  only from a CLI/dial context that has no `SessionIdentity` of its own to fall
  back to.
- If a new bind site is ever added (a second app entry point, a preview target,
  etc.), it must use `listenPath(for:)`.
- `SessionIdentity.controlSocketPath()`/`.debugSocketPath` themselves read no
  env var, so the disambiguation is purely the `--session` name — safe as long
  as callers pick the right one of the two resolvers above.
- See [[app-sessions]] and [[domain-cli-control-channel]] for the surrounding
  session/env-injection design.
