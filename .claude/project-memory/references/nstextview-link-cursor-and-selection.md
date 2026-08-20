---
name: "Link cursor and selection in the info panel"
description: "A SwiftUI Text has no per-link hover hook; NSTextView gives selection, but the pointing-hand cursor must be driven explicitly"
type: reference
---

# Link cursor and selection in the info panel

SwiftUI's `Text` renders every inline link as a `.link` attribute set on an
`AttributedString` inside one `Text`-backed block, with no per-link `View` to
attach `.onHover` to. A `Text` block made selectable with
`.textSelection(.enabled)` shows the I-beam over links as well, and application
code cannot special-case the cursor for the link runs inside it.

`MarkdownTextView` (`Sources/CasperUI/MarkdownTextView.swift`) hosts the
rendered Markdown in a read-only, selectable `NSTextView` instead. That buys
text selection and ⌘C, and — unlike a `Text` — it exposes the character index
under the pointer and the attributes at that index, which is what makes a
link-aware cursor possible at all.

**The pointing-hand cursor is not free.** Hosted this way, `NSTextView` does
**not** show it on its own — verified in the running app, where links keep the
I-beam. The view therefore drives the cursor itself, following
[[terminal-overlay-cursor]] — a tracking area rebuilt over the visible rect
(the panel scrolls inside a SwiftUI `ScrollView`), the cursor set from
`cursorUpdate(with:)`, `mouseEntered(with:)`, and `mouseMoved(with:)`, and the
character index under the pointer tested for a `.link` attribute to choose
between `NSCursor.pointingHand` and the I-beam.

**How to apply:** keep the panel on an `NSTextView`; a `Text`-based renderer
would lose both the cursor and the hook that makes it reachable. Headless tests
can pin the index-to-attribute logic, never the cursor image — that check is a
human one (see [[agent-visual-verification-limits]]).
