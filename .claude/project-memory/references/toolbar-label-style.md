---
name: "Toolbar Labels resolve to icon-only"
description: "A Label inside a macOS .toolbar drops its title unless .labelStyle(.titleAndIcon) is pinned"
type: reference
---

# Toolbar Labels resolve to icon-only

Inside a macOS `.toolbar`, SwiftUI puts an icon-only label style in the
environment, so a `Label("Merge", systemImage:)` renders as the bare glyph and
the title is silently dropped. Toolbar chips that are meant to read as text
pin the style explicitly with `.labelStyle(.titleAndIcon)`.

This holds even for a chip drawn by a `Button` with `.buttonStyle(.plain)` and
its own `titleCapsule()` background: the style is inherited from the toolbar
environment, not from the capsule.

**Why it matters:** title-bar chips are a set. Editor and Run
(`Sources/CasperUI/WorkspaceDetailView.swift`) are text-bearing, so a
glyph-only neighbour reads as a different class of control.

**Ordering:** the style modifier goes on the `Label` BEFORE `titleCapsule()`,
which stays the outermost modifier on the label content — see
[[title-capsule-hit-area]].
