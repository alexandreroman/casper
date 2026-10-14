---
name: "Swift toolchain floor"
description: "Casper requires Swift 6.2+ (Xcode 26); CI/release Xcode pin must stay >= 26"
type: reference
---

# Swift toolchain floor

The floor itself — **Swift 6.2 / Xcode 26** — is stated in `CLAUDE.md` § Tech
stack and `README.md`. What sets it is
`Sources/CasperGhostty/GhosttySurfaceView.swift`'s main-actor **isolated
conformance** — `public final class GhosttySurfaceView: NSView,
@MainActor NSTextInputClient` — which is Swift 6.2's SE-0470. `Package.swift`
declares `swift-tools-version: 6.2`, so an older toolchain stops before
compiling anything, with "requires minimum Swift tools version 6.2".

**CI/release pin:** `.github/workflows/ci.yml` and `release.yml` pin
`maxim-lobanov/setup-xcode@v1` to **`26.3`**. Keep both at Xcode **>= 26** and
move them together, or the release build breaks even when CI passes. CI runs a
`macos-15` / `macos-26` matrix, and the `macos-15` image ships Xcode 16.0–16.4
plus 26.0.1–26.3 with 16.4 as the default, which fails — so the pin must name a
26.x present on **both** images. The release job runs on `macos-26`.

Any code relying on `@MainActor` isolated conformances or other Swift 6.2+
syntax will compile locally (dev toolchain is Xcode 26.x) but silently gate the
runner — verify the CI Xcode pin covers the language features used.
