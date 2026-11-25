---
name: "AttributedString interop limits"
description: "HighlightSwift emits AppKit-scope attributes on macOS and returns its input text exactly; AttributedString.utf16 needs macOS 26"
type: reference
---

# AttributedString interop limits

## Carrying HighlightSwift output into AppKit

Three properties bound how HighlightSwift's output can be carried into AppKit
text. The working recipe lives in `Sources/CasperUI/DiffTextAssembly.swift`
(scope and run lengths) and `Sources/CasperUI/DiffHighlighter.swift` (line
alignment).

- **HighlightSwift returns AppKit-scope attributes on macOS.** Its
  `attributedTextFromData` ends in
  `AttributedString(attributedString, including: \.appKit)`, so a run's color is
  an `NSColor` under `run.attributes.appKit.foregroundColor`. The SwiftUI scope
  is empty: `run.attributes.swiftUI.foregroundColor` is `nil` for every run of
  every highlighted line. HighlightSwift also removes `.font` itself before
  converting, and `DiffTextAssembly.applyHighlight` copies nothing but
  `appKit.foregroundColor`, so nothing strips fonts to keep a uniform
  monospaced face.
- **HighlightSwift's output text is its input text, or an uncolored copy.**
  Since HighlightSwift 1.2.0 it escapes each CR as `&#13;`, imports the
  `<pre><code>` HTML on the main actor, and keeps exactly the source's UTF-16
  length when the import starts with the source; otherwise it returns plain
  `AttributedString(source)`. `DiffHighlighter.normalizingLineEndings`
  hands it a CRLF as an LF and a lone CR as a space, the way `DiffDocument`
  shows it, so the lines it returns are the diff's lines.
  `DiffHighlighter.lines(fromLibraryOutput:alignedTo:)` returns `nil` — the
  file stays neutral — unless the output equals the source **scalar by
  scalar**: a matching line count alone can still hide a moved line break, and
  `String ==` (canonical equivalence) can hide a changed scalar.
  `DiffHighlighterTests` rebuilds the library's output shape (CR escape,
  `<pre><code>`, HTML import, source-length cut) without JavaScript.
- **`AttributedString.utf16` requires macOS 26.** Casper's floor is macOS 15
  (see [[swift-toolchain-floor]]), so a run's UTF-16 length is measured with
  `UTF16.width` over the run slice's `unicodeScalars`.

**Why:** reading the wrong scope fails silently and totally — every length and
range check still agrees, so the text renders fully neutral with no error and no
log, indistinguishable from "language unknown". And measuring a run with
`String(slice.characters).utf16.count` rounds to grapheme boundaries, so offsets
drift whenever a run boundary falls inside a cluster, misaligning every later
run in the line.

**How to apply:** read the AppKit scope when consuming HighlightSwift output
(see [[highlightswift-shared-instance]]). Pin the contract with a test whose
input comes from `AttributedString(nsAttributedString, including: \.appKit)` — a
test that builds its own SwiftUI-scope `AttributedString` asserts against the
wrong scope and passes while production applies nothing. The real producer is
not available as a test input: under `swift test`, `Bundle.main` is the
toolchain's `usr/bin`, so HighlightSwift's resource bundle cannot be found and
`DiffHighlighter.highlightedLines` returns `nil` (see
[[highlightswift-resource-bundle]]). Note that a test comparing colors needs
`import SwiftUI` for `Color`-typed literals to resolve, and that
`NSColor.purple` and `NSColor(Color.purple)` are different colors.

