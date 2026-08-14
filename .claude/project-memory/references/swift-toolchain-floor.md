---
name: swift-toolchain-floor
description: "Casper requires Swift 6.2+ (Xcode 26); CI/release Xcode pin must stay >= 26"
type: reference
---

# swift-toolchain-floor

Casper's minimum toolchain is **Swift 6.2 / Xcode 26**, not Swift 6.0/6.1.
`Sources/CasperGhostty/GhosttySurfaceView.swift` conforms with a
main-actor **isolated conformance** — `public final class GhosttySurfaceView:
NSView, @MainActor NSTextInputClient` — which is Swift 6.2's SE-0470. Older
compilers reject it with `error: unknown attribute 'MainActor'`, cascading into
~30 actor-isolation errors on every `NSTextInputClient` method. Swift 6.1
(Xcode 16.3/16.4) does **not** support it; the feature landed in Swift 6.2.

**CI/release pin:** `.github/workflows/ci.yml` and `release.yml` pin
`maxim-lobanov/setup-xcode@v1` to **`26.3`**. Keep this at Xcode **>= 26** —
the `macos-15` runner image ships Xcode 16.0–16.4 plus 26.0.1–26.3, so both
workflows must select a 26.x explicitly (the default is 16.4, which fails).
Both pins must move together, or the release build breaks even when CI passes.
CI runs a `macos-15` / `macos-26` matrix, so a pin bump has to be a version
present on **both** images.

Any code relying on `@MainActor` isolated conformances or other Swift 6.2+
syntax will compile locally (dev toolchain is Xcode 26.x) but silently gate the
runner — verify the CI Xcode pin covers the language features used.
