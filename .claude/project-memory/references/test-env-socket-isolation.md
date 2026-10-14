---
name: "Test isolation from Casper socket env vars"
description: "make test strips CASPER_CONTROL_SOCKET/CASPER_DEBUG_SOCKET/CASPER_SESSION so ambient Casper terminal env never leaks into swift test"
type: project
---

# Test isolation from Casper socket env vars

`make test` strips `CASPER_CONTROL_SOCKET`, `CASPER_DEBUG_SOCKET`, and
`CASPER_SESSION` (`env -u ... swift test`) before running the test suite.
`DebugSocketPath.resolve(for:)`/`.default` (CasperCore) reads
`CASPER_DEBUG_SOCKET` and lets it override the session-derived socket path, and
the control-channel dial path in `CasperCLI/ControlClient.swift` takes its
socket path from `CASPER_CONTROL_SOCKET` alone — both intentional for the
`casper` CLI/`casper debug`, but every terminal Casper opens (dev or a bundled
`Casper.app`, including an unnamed default-session instance) injects
`CASPER_CONTROL_SOCKET` (and `CASPER_SESSION` for named sessions) via
`AgentEnvironment.surfaceEnvironment`. Running `swift test` directly inside such
a terminal (a normal dogfooding workflow for this repo) therefore leaks the live
instance's real socket path into the test process.

**Why:** without the strip, the env-sensitive assertions silently skip: run
inside a terminal that exports `CASPER_DEBUG_SOCKET`, `swift test --filter
SocketPathResolutionTests` skips `testDebugResolveNamedSession`
(`skipWhenDebugSocketIsOverridden`), because the ambient variable would override
the `SessionIdentity` argument passed to `resolve(for:)`.
This only affects *assertions on the resolved path string* — no test binds a
real listener at that default/session path (every test that opens a real socket
uses its own UUID-suffixed temp path), so the live socket **file** is never at
risk of being unlinked/rebound; the hazard is test-hermeticity, not socket
corruption.

**How to apply:**

- Always run tests via `make test`, not a bare `swift test`, when inside a
  Casper terminal — `make test` is hermetic against this leak regardless of
  which instance (or session) opened the terminal.
- Two test files guard their env-independent-derivation assertions themselves:
  `SocketPathResolutionTests.swift` and `DebugSocketTests.swift`. Both use
  `try XCTSkipUnless(…)` against the ambient `CASPER_*` variable. Skipping
  rather than silently returning is the point — a `guard … else { return }`
  reports a vacuous pass. These guards are defense in depth for a bare
  `swift test` run; `make test` covers the common case.
- If Casper starts injecting a new per-surface env var in the future, add it to
  both the `make test` strip list and, ideally, avoid a bespoke per-test guard
  as the *only* line of defense — the Makefile-level fix is the precedent to
  prefer over relying on every test author remembering a guard.
- See [[app-sessions]] (the analogous collision for live GUI verification, not
  test runs) and `.superpowers/themes/cli-agents.md` § Agent state & progress
  (why `CASPER_CONTROL_SOCKET` is injected at all).
