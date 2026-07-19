---
name: "HighlightSwift Highlight() must be reused, never per-call"
description: "Each Highlight() spins up its own JavaScriptCore JSContext; per-call construction leaks GBs under diff churn"
type: reference
---

# HighlightSwift Highlight() must be reused, never per-call

`HighlightSwift.Highlight` (a `Sendable final class`) owns an `HLJS` **actor**
that lazily creates a **new JavaScriptCore `JSContext`** and re-evaluates the
whole `highlight.min.js` on first use. Constructing a fresh `Highlight()` per
highlight call therefore spins up a new `JSContext`/`JSVirtualMachine` every
time. JavaScriptCore allocates VM-heap memory per context and does **not**
return it to the OS.

`DiffSurfaceView.startHighlighting` runs on **every diff refresh**, spawning a
`Task` that highlights each changed file. Under sustained agent-driven file
changes with the diff visible, refreshes outpace highlighting, so many highlight
calls overlap — each with its own `JSContext`. This is what drove Casper RSS
into the gigabytes (200 MB → 2 GB in tens of minutes with 3–4 workspaces) that
**never receded** even after activity stopped.

Fix: `DiffHighlighter` keeps **one shared** `private static let highlighter =
Highlight()` and reuses it. Concurrent calls serialise through its `HLJS` actor
(one warm context), bounding memory. Isolation measurement of the exact call
pattern under concurrent load: per-call ~490 MB (stays put when idle) vs shared
~65 MB.

**Rule:** never write `Highlight().attributedText(...)` at a call site that can
fire repeatedly/concurrently — always go through the shared `DiffHighlighter`
instance. The leak was invisible to object-lifecycle instrumentation (the
`Highlight`/`JSContext` objects *do* deallocate); it lives in JavaScriptCore's
retained VM heap, so diagnose this class of leak with `vmmap`/`footprint`
category deltas, not just live-instance counts.
