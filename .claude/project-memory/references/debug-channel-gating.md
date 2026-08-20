---
name: "Debug channel and logging gating"
description: "Debug control channel is #if DEBUG only; verbose logs gated, errors kept"
type: feedback
---

# Debug channel and logging gating

The debug/observability control channel (the `casper debug` subcommand, its
`DebugSocketServer`, and the GUI wiring that exposes surfaces to it) is gated
**entirely by `#if DEBUG`** and must **never** be present in a distributed
release. Enablement is 100 % compile-time — no runtime flag or environment
variable may turn it on in a release binary. The `CASPER_DEBUG_SOCKET`
environment variable only selects the socket *path*, never whether the channel
exists.

Structured logging (`CasperLog` over `os.Logger`) follows the same rule with a
diagnostic floor: `.error`/`.fault` stay compiled in for field crash diagnosis;
`.debug`/`.info` verbose events are gated by `#if DEBUG`.

**Scope note:** this gating applies only to the `casper debug` /
`DebugSocketServer` channel. The separate domain **control channel** (`status`/
`progress`/`notify`/`terminal`/`browser`/`diff`/`workspace`, over
`$CASPER_CONTROL_SOCKET`) ships in every release build by design — see
[[domain-cli-control-channel]]. Do not conflate the two when reasoning about
what is release-safe.

**Why:** the debug channel is an injectable local control socket; leaving it in a
shipped build is an attack surface, and it must never reach a distributed
release. `#if DEBUG` guarantees absence by construction because
`make release` builds `-c release`, where `DEBUG` is undefined — a dedicated
`-D` flag would leave room for accidental release activation. Logging errors are
kept because `os.Logger` is privacy-preserving and near-zero cost, and is the
only way to diagnose a crash reported from the field.

**How to apply:** wrap the whole control-channel code path and its `casper
debug` subcommand registration in `#if DEBUG`. For logs, keep `.error`/`.fault`
unconditional and wrap `.debug`/`.info` call sites in `#if DEBUG`. Prefer tying
gating to the build configuration (`#if DEBUG`) over a custom compilation flag.
See the [dependency policy](dependency-policy.md) note and the spec at
`.superpowers/themes/debug.md`.

**Cross-module visibility gotcha:** `GhosttySurfaceView`'s `debug*` accessors
(`debugHasSurface`, `debugReadText`, `debugSendText`, `debugSendKeys`,
`debugSendKey`, `debugSendAction`, `debugMouseMove`, `debugGeometry`) live in
`CasperGhostty`. They must be `public`: an `internal` accessor compiles inside
`CasperGhostty` itself but not from a `DebugSurfaceProvider` conformance
written in a different target — which is where the conformance lives
(`CasperUI`'s `DebugSurfaceBridge.swift`). `DebugSurfaceHandle`,
`DebugSurfaceGeometry`, `DebugSurfaceProvider`, and `DebugServer` are already
`public` in `Sources/CasperGhostty/DebugServer.swift`; `DebugSocketPath` is
`public` in `Sources/CasperCore/DebugSocket.swift`. `#if DEBUG` still fully
compiles these out of a release build regardless of access level.
