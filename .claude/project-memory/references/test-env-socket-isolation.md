---
name: "Test isolation from Casper socket env vars"
description: "make test strips CASPER_CONTROL_SOCKET/CASPER_DEBUG_SOCKET/CASPER_SESSION so ambient Casper terminal env never leaks into swift test"
type: project
---

# Test isolation from Casper socket env vars

`make test` strips `CASPER_CONTROL_SOCKET`, `CASPER_DEBUG_SOCKET`, and
`CASPER_SESSION` (`env -u ... swift test`) before running the test suite.
`ControlSocketPath.resolve(for:)`/`DebugSocketPath.resolve(for:)`/`.default`
(CasperCore) read these env vars and let them override the session-derived
socket path — intentional for the `casper` CLI/`casper debug`, but every
terminal Casper opens (dev or a bundled `Casper.app`, including an unnamed
default-session instance) injects `CASPER_CONTROL_SOCKET` (and
`CASPER_SESSION` for named sessions) via `ClaudeCodeAdapter.surfaceEnvironment`.
Running `swift test` directly inside such a terminal (a normal dogfooding
workflow for this repo) therefore leaks the live instance's real socket path
into the test process.

**Why:** reproduced live — `swift test --filter SocketPathResolutionTests`
run inside a terminal opened by a real bundled `Casper.app` failed
`testControlResolveNamedSession` because the ambient `CASPER_CONTROL_SOCKET`
silently overrode the `SessionIdentity` argument passed to `resolve(for:)`.
This only affects *assertions on the resolved path string* — no test ever
binds a real listener at that default/session path (every test that opens a
real socket uses its own UUID-suffixed temp path), so the live socket
**file** itself was never at risk of being unlinked/rebound; the bug was
test-hermeticity, not socket corruption.

**How to apply:**

- Always run tests via `make test`, not a bare `swift test`, when inside a
  Casper terminal — `make test` is now hermetic against this leak regardless
  of which instance (or session) opened the terminal.
- `SocketPathResolutionTests.swift`, `ControlSocketTests.swift`, and
  `DebugSocketTests.swift` also each guard their env-independent-derivation
  assertions with `guard ProcessInfo.processInfo.environment["CASPER_..."] ==
  nil else { return }` as defense in depth for a bare `swift test` run — kept
  intentionally even though `make test` now makes them redundant in the
  common case.
- If Casper starts injecting a new per-surface env var in the future, add it
  to both the `make test` strip list and, ideally, avoid a bespoke per-test
  guard as the *only* line of defense — the Makefile-level fix is the
  precedent to prefer over relying on every test author remembering a guard.
- See [[app-sessions]] (the analogous collision for live GUI verification,
  not test runs) and [[domain-cli-control-channel]] (why
  `CASPER_CONTROL_SOCKET` is injected at all).
