---
name: "AttributedString interop limits"
description: "HighlightSwift emits AppKit-scope attributes on macOS, AttributedString.utf16 needs macOS 26, and the AppKit scope can only be edited through NSAttributedString"
type: reference
---

# AttributedString interop limits

## Carrying HighlightSwift output into AppKit

Two properties of `AttributedString` bound how HighlightSwift's output can be
carried into AppKit text. The working recipe for both lives in
`Sources/CasperUI/DiffTextAssembly.swift`.

- **HighlightSwift returns AppKit-scope attributes on macOS.** Its
  `attributedTextFromData` ends in
  `AttributedString(attributedString, including: \.appKit)`, so a run's color is
  an `NSColor` under `run.attributes.appKit.foregroundColor`. The SwiftUI scope
  is empty: `run.attributes.swiftUI.foregroundColor` is `nil` for every run of
  every highlighted line. HighlightSwift also removes `.font` itself before
  converting, which is why nothing downstream has to strip fonts to keep a
  uniform monospaced face.
- **`AttributedString.utf16` requires macOS 26.** Casper's floor is macOS 15
  (see [[swift-toolchain-floor]]), so a run's UTF-16 length is measured with
  `UTF16.width` over the run slice's `unicodeScalars`.

**Why:** reading the wrong scope fails silently and totally — every length and
range check still agrees, so the text renders fully neutral with no error and no
log, indistinguishable from "language unknown". And measuring a run with
`String(slice.characters).utf16.count` rounds to grapheme boundaries, so offsets
drift whenever a run boundary falls inside a cluster, misaligning every later run
in the line.

**How to apply:** read the AppKit scope when consuming HighlightSwift output (see
[[highlightswift-shared-instance]]). Pin the contract with a test whose input
comes from `AttributedString(nsAttributedString, including: \.appKit)` — a test
that builds its own SwiftUI-scope `AttributedString` asserts against the wrong
scope and passes while production applies nothing. The real producer is not
available as a test input: under `swift test`, `Bundle.main` is the toolchain's
`usr/bin`, so HighlightSwift's resource bundle cannot be found and
`DiffHighlighter.highlightedLines` returns `nil` (see
[[highlightswift-resource-bundle]]). Note that a test comparing colors needs
`import SwiftUI` for `Color`-typed literals to resolve, and that
`NSColor.purple` and `NSColor(Color.purple)` are different colors.

## Editing the AppKit scope goes through `NSAttributedString`

Four constraints hold on this toolchain, each established by `swiftc -typecheck`
probes and runtime checks:

- **`AttributedString` has no `removeAttribute` / `removeAttributes`.** Both
  names resolve only to the `AttributeContainer` dynamic-member subscript and
  fail to type-check.
- **The `Sendable` requirement sits on the attribute *key*, not on the write.**
  Every typed reference to `AttributeScopes.AppKitAttributes.FontAttribute`
  warns — writing `nil`, a plain read (`_ = line.appKit.font`) and subscripting
  by key type alike. `transformingAttributes(FontKey.self) { $0.value = nil }`
  is a hard **error**, not a warning.
- **`@preconcurrency import AppKit` does not suppress it.** It changes nothing.
- **`including: \.swiftUI` is not a superset of `including: \.appKit`.**
  Decoding an `NSAttributedString` through the SwiftUI scope leaves
  `run.attributes.appKit.foregroundColor` nil, so it cannot substitute for the
  AppKit decode. The reverse nesting does hold: `including: \.appKit` nests the
  Foundation scope (a `.link` survives), and an `AttributedString` →
  `NSMutableAttributedString` → `AttributedString(including: \.appKit)` round
  trip is lossless for AppKit-scope input, colors and links intact.

**How to apply:** strip an AppKit-scope attribute with the untyped
`NSAttributedString.Key` (e.g. `.font`) on a bridged `NSMutableAttributedString`
and decode the result back with `including: \.appKit`, which keeps the
`Sendable` check out of it. `droppingFonts(_:)` in
`Sources/CasperUI/DiffHighlighter.swift` is the working example.
