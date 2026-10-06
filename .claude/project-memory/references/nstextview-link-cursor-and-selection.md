---
name: "Link cursor and selection in the info panel"
description: "NSTextView gives selection; the pointing-hand cursor and Command-click on a link must both be handled explicitly"
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
[[terminal-overlay-cursor]] — a tracking area rebuilt over the visible rect (the
panel scrolls inside a SwiftUI `ScrollView`), the cursor set from
`cursorUpdate(with:)`, `mouseEntered(with:)`, and `mouseMoved(with:)`, and the
character index under the pointer tested for a `.link` attribute to choose
between `NSCursor.pointingHand` and the I-beam.

**Command-click is not free either.** `NSTextView` spends Command on a click:
it toggles a discontiguous selection. Once the text view is first responder and
receives the Command press through `flagsChanged:`, the next Command-click
enters AppKit's private selection tracking
(`_bellerophonTrackMouseWithMouseDownEvent:…toggling:YES…`) and
`clickedOnLink:atIndex:` never fires — the click opens nothing. Command held
*before* the popover opens skips that path, which makes the failure look
position- or timing-dependent. It rests on AppKit private state: a headless
`NSTextView` driven by synthetic events always reaches `clickedOnLink`, so no
test reproduces it. `LinkCursorTextView.mouseDown(with:)` therefore handles a
Command-click on a link itself and calls `clicked(onLink:at:)`, which keeps the
delegate path (and its `NSApp.currentEvent` modifier read) intact.

**Diagnosing clicks in the live app:** an agent's terminal has no
Accessibility, Screen Recording, or event-posting rights, so it cannot click
or see the window (see [[gui-synthetic-input]]). `lldb` attached to the dev
process, with auto-continuing breakpoints (`-G true`) on `-[NSTextView
mouseDown:]`, `flagsChanged:`, `clickedOnLink:atIndex:` and the coordinator's
Swift symbol, traces what AppKit does while the user performs the clicks.

**How to apply:** keep the panel on an `NSTextView`; a `Text`-based renderer
would lose both the cursor and the hook that makes it reachable. Keep the
Command-click interception — removing it brings back links that open nothing.
Headless tests can pin the index-to-attribute logic and the interception, never
the cursor image nor AppKit's toggling path — those checks are human ones (see
[[agent-visual-verification-limits]]).
