---
name: "Debug screenshot uses ScreenCaptureKit"
description: "At the macOS 15 target CGWindowListCreateImage is obsoleted; the DEBUG screenshot verb uses SCScreenshotManager (async, needs screen-recording permission)"
type: reference
---

# Debug screenshot uses ScreenCaptureKit

The debug-only `screenshot` verb (`Sources/CasperGhostty/DebugServer.swift`,
`#if DEBUG`) captures the window via **ScreenCaptureKit**
(`SCScreenshotManager.captureImage`), not `CGWindowListCreateImage`.

**Why:** the project deployment target is **macOS 15** (see `Package.swift`
`.macOS(.v15)` and `CLAUDE.md`). At that target `CGWindowListCreateImage` is
**obsoleted** — a hard compile error, not just a deprecation — so it cannot be
used. A plain view/bitmap capture can't read a Metal-rendered (libghostty)
window's pixels, so ScreenCaptureKit is the only correct replacement. The
migration made `screenshot(window:to:)` `async`, which ripples `async` up
through its private callers in the same file.

**How to access:** the `casper debug screenshot <path>` CLI (see the
`debug-casper` skill) requires the **screen-recording permission**; if a capture
returns empty or fails, check that permission for the debug binary. Release
builds omit this path entirely (`#if DEBUG`).
