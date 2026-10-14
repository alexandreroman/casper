---
name: "HighlightSwift Highlight() must be reused"
description: "Each Highlight() spins up its own JavaScriptCore JSContext; per-call construction leaks GBs under diff churn"
type: reference
---

# HighlightSwift Highlight() must be reused

`HighlightSwift.Highlight` (a `Sendable final class`) owns an `HLJS` **actor**
that lazily creates a **new JavaScriptCore `JSContext`** and re-evaluates the
whole `highlight.min.js` on first use. Constructing a fresh `Highlight()` per
highlight call therefore spins up a new `JSContext`/`JSVirtualMachine` every
time. JavaScriptCore allocates VM-heap memory per context and does **not**
return it to the OS.

Every diff refresh highlights each changed file, and under agent-driven churn
those calls overlap, so per-call construction multiplies contexts — memory that
never recedes, even after activity stops. `DiffHighlighter` therefore keeps one
shared `private static let highlighter = Highlight()`; concurrent calls
serialise through its `HLJS` actor, one warm context, which bounds memory.

**Rule:** never write `Highlight().attributedText(...)` at a call site that can
fire repeatedly/concurrently — always go through the shared `DiffHighlighter`
instance. This class of leak is invisible to object-lifecycle instrumentation
(the `Highlight`/`JSContext` objects *do* deallocate); it lives in
JavaScriptCore's retained VM heap, so diagnose this class of leak with
`vmmap`/`footprint` category deltas, not just live-instance counts.
