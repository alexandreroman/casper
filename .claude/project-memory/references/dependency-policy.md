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

Only **five** external dependencies are sanctioned — **GhosttyKit** (libghostty
terminal engine), **swift-argument-parser** (CLI), **libgit2** (Git, wrapped
in an in-house `CasperGit` module; no external `git` binary),
**HighlightSwift** (appstefan, MIT — language-aware syntax highlighting for the
inspector diff view), and **Sparkle** (auto-update). Everything else must use
system frameworks
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

**Sparkle exception (approved by Alexandre):** macOS offers no in-app update
mechanism outside the App Store, and Casper is distributed as a direct download.
Sparkle is the de facto standard and the only realistic option; writing an
updater in-house means re-implementing signature verification and atomic bundle
replacement, which is exactly the kind of security-critical code not worth
owning. It ships a universal `Sparkle.framework` (~10 MB in the bundle) — the one
place where the smallest-binary rule is knowingly traded away. Casper stays
ad-hoc signed, so the EdDSA appcast signature is the only trust anchor: see
[`.superpowers/plans/sparkle-auto-update.md`](../../../.superpowers/plans/sparkle-auto-update.md).

**Workspace info panel rendering:** the panel renders Markdown supplied by the
`casper info` CLI without any external package. macOS parses Markdown natively
(`AttributedString(markdown:)` with `interpretedSyntax: .full`), and
`MarkdownAttributedString` (`Sources/CasperUI/MarkdownAttributedString.swift`)
turns the resulting block-level `presentationIntent` into a styled
`NSAttributedString` — headings, lists, code blocks, block quotes, and GFM
tables (via `NSTextTable`) all come from that hand-rolled renderer, not a
library. `MarkdownTextView` (`Sources/CasperUI/MarkdownTextView.swift`) hosts
that attributed string in a read-only, selectable `NSTextView` (TextKit),
which is also what gives the panel the native pointing-hand cursor over a
link — a SwiftUI `Text` cannot do that (see the
`nstextview-link-cursor-and-selection` project memory note). Images
(`![alt](url)`) render as their alt text only, so the panel makes no network
requests of its own.
