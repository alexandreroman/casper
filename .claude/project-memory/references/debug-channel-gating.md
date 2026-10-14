---
name: "Debug channel and logging gating"
description: "Debug control channel is #if DEBUG only; verbose logs are gated and error logs ship"
type: feedback
---

# Debug channel and logging gating

The debug channel (`casper debug`, its socket server and the GUI bridge) and
the verbose `.debug`/`.info` logs are gated at compile time by `#if DEBUG`; the
hard constraint and the logging floor are stated in
`.superpowers/themes/debug.md` § Hard constraint. No runtime flag or environment
variable may enable the channel in a release binary.

**Scope note:** the gating covers only the `casper debug` channel. The domain
control channel ships in every release build by design — see
[[domain-cli-control-channel]] — and so does the generic framing engine both
channels build on, `Sources/CasperCore/SocketTransport.swift`. Do not conflate
the two when reasoning about what is release-safe.

**Why:** the debug channel is an injectable local control socket; leaving it in
a shipped build is an attack surface, and it must never reach a distributed
release. `#if DEBUG` guarantees absence by construction because `make release`
builds `-c release`, where `DEBUG` is undefined — a dedicated `-D` flag would
leave room for accidental release activation. Error logging ships in release
because `os.Logger` is privacy-preserving and near-zero cost, and is the only
way to diagnose a crash reported from the field.

**How to apply:** wrap the whole `casper debug` code path and its subcommand
registration in `#if DEBUG`, leaving the shared transport out of the guard. For
logs, keep `.notice`/`.error`/`.fault` unconditional and wrap `.debug`/`.info`
call sites in `#if DEBUG`. Tie gating to the build configuration (`#if DEBUG`),
never to a custom compilation flag.

**Cross-module visibility gotcha:** `GhosttySurfaceView`'s `debug*` accessors
(`debugHasSurface`, `debugReadText`, `debugSendText`, `debugSendKeys`,
`debugSendKey`, `debugSendAction`, `debugMouseMove`, `debugGeometry`) live in
`CasperGhostty`. They must be `public`: an `internal` accessor compiles inside
`CasperGhostty` itself but not from a `DebugSurfaceProvider` conformance written
in a different target — which is where the conformance lives (`CasperUI`'s
`DebugSurfaceBridge.swift`). `DebugSurfaceHandle`, `DebugSurfaceProvider`, and
`DebugServer` are already `public` in `Sources/CasperGhostty/DebugServer.swift`;
`DebugSocketPath` is `public` in `Sources/CasperCore/DebugSocket.swift`.
`#if DEBUG` still fully compiles these out of a release build regardless of
access level.
