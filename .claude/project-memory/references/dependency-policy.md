---
name: dependency-policy
description: "Casper's strict dependency-minimalism stance and the only allowed external deps"
type: feedback
---

# dependency-policy

Casper is a **native, performant macOS app** that **always prefers built-in
macOS frameworks**, with the **smallest possible binary** and **minimum external
dependencies**.

**Why:** it is a distributable product where size and native feel matter;
heavyweight stacks are rejected (e.g. no Chromium/CEF — the browser is WKWebView).

**How to apply:** default to **native macOS APIs and frameworks** for every
task. Before reinventing something OR reaching for a library, check whether the
OS already provides it — e.g. `NSImage(data:)` decodes SVG markup natively on
macOS 14+ (a vector `_NSSVGImageRep`; set `isTemplate = true` to tint it via
SwiftUI `.foregroundStyle`), so rendering an octicon needs neither a custom SVG
parser nor an SVG library.

Only **four** external dependencies are sanctioned — **GhosttyKit** (libghostty
terminal engine), **swift-argument-parser** (CLI), **libgit2** (Git, wrapped
in an in-house `CasperGit` module; no external `git` binary), and
**HighlightSwift** (appstefan, MIT — language-aware syntax highlighting for the
inspector diff view). Everything else must use system frameworks
(Network.framework, WebKit, UserNotifications, AppKit/SwiftUI, Foundation/Codable).
Build **arm64-only**, release with `-Osize` + LTO + strip. Before adding any new
package, stop and justify it against this policy.

**HighlightSwift exception (approved):** macOS ships no general-purpose,
multi-language syntax highlighter, so the diff view's language-aware coloring
needs a library. HighlightSwift was chosen over the tree-sitter stack
(SwiftTreeSitter + Neon + one grammar/query package per language — a dozen+ C
targets, Neon pre-1.0, AppKit/TextKit-oriented) because it is a single
dependency, Swift 6 strict-concurrency clean, SwiftUI-native, and produces an
`AttributedString` directly. It wraps highlight.js via **JavaScriptCore** (a
system framework), so only the JS text asset is bundled — no extra binary. Pinned
at 1.1.0.
