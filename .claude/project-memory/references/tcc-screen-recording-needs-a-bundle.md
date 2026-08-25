---
name: "Screen Recording is granted to app bundles, not to signed binaries"
description: "A loose Mach-O never appears in the Screen Recording list whatever its identity; this is why make build assembles Casper-dev.app"
type: reference
---

# Screen Recording is granted to app bundles, not to signed binaries

For Screen Recording specifically, TCC and System Settings only enumerate and
prompt for real `.app` bundles — an `Info.plist` on disk at a conventional path.
A bare signed executable **never appears in the list at all** and can never be
granted the permission.

**Why:** this was tested end to end, against the plausible theory that TCC
matches on code identifier plus Team ID regardless of bundle structure. It does
not. Signing `.build/debug/casper` in place with a real `Apple Development`
identity and a fixed `--identifier` still failed on the very first capture with
`SCStreamErrorDomain Code=-3801 "The user declined TCCs…"`, and no system prompt
ever appeared. Renaming the identifier changed nothing. Embedding an
`NSScreenCaptureUsageDescription`-bearing `Info.plist` into the executable via
the linker (`-sectcreate __TEXT __info_plist`) — a real technique that works for
other TCC services in a bare SwiftPM binary — changed nothing either. System
Settings → Privacy & Security → Screen & System Audio Recording listed only real
bundles throughout.

**How to apply:** this is why `make build` assembles and signs
`Packaging/Casper-dev.app` around the debug binary rather than signing the
binary in place, and why the identity must be **stable** across rebuilds — TCC
keys the grant to it, so an ad-hoc identity (which changes every build) makes
the user re-grant permission after every rebuild. `Makefile` explains the
`CODESIGN_IDENTITY` setup at its two mentions of the grant. The consumer is the
`debug-casper` skill's `screenshot` verb — see
[[debug-screenshot-screencapturekit]] and [[gui-synthetic-input]].

A minimal bundle is therefore **required, not optional**, for any TCC service
reached this way.
