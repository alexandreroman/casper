---
name: "Ghostty is the reference implementation"
description: "For native macOS terminal UI/interaction features, match Ghostty's macOS Swift source rather than improvising a mechanism"
type: feedback
---

# Ghostty is the reference implementation

For native macOS terminal UI and interaction features — splits, drag-and-drop,
cursor handling, keyboard, window/toolbar behaviour — **match Ghostty's macOS
Swift source** (`github.com/ghostty-org/ghostty`, `macos/Sources/…`) as the
reference implementation instead of inventing a mechanism.

**Why:** improvised approaches in this project caused repeated regressions
(the pane-grip cursor alone went through cursor rects, `push`/`pop`, `set`, and
back before landing on Ghostty's `cursorUpdate` pattern). Ghostty's proven choices
resolved each one: `cursorUpdate` for terminal-overlay cursors, an AppKit
`NSView` drag source with edge-based `DropZone`s, SwiftUI `.pointerStyle` for the
resize divider. It is the authoritative model because it solves the same problems
against the same embedded-libghostty constraints.

**How to apply:** before implementing such a feature, read the matching file under
Ghostty's `macos/Sources/` and adopt its mechanism. Deviate only for a genuine
Casper-specific constraint (e.g. no `Info.plist`, see
[[intra-app-drag-pasteboard-type]]), and say so. Related:
[[terminal-overlay-cursor]].
