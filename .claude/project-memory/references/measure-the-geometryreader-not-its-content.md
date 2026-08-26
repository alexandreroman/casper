---
name: "Measure the GeometryReader, not content that can overflow its column"
description: "A view whose content exceeds its column reports the overflowing width to onGeometryChange; a GeometryReader takes exactly the space offered, so reading the reader is what yields the column's real width"
type: reference
---

# Measure the GeometryReader, not content that can overflow its column

`.onGeometryChange` reports the width a view *claims*, which is not the width its
column *has*. A stack whose children cannot compress — a detail area holding an
inspector panel with a minimum width of its own — lays out wider than its column
and is clipped, and it reports that overflowing width: measured 241 pt for a
150 pt column. A `GeometryReader` cannot overflow, because it takes exactly the
space it is offered, so reading the reader's own frame is what yields the truth.

**Why:** the number looks entirely plausible and is wrong only in the states
where the content overflows — so a measurement-driven layout behaves correctly
at every width until some *other* panel opens, and then silently gets a width
that does not exist. In the title bar this reads as the whole row jumping into
AppKit's overflow chevron the moment the diff panel opens at a narrow window,
which recovers on nothing (see [[toolbar-overflows-before-squeezing]]).

**How to access:** `WorkspaceDetailView`'s row width comes from
`.onGeometryChange` attached to the `GeometryReader` itself rather than to the
`HStack` inside it. The regression test asserts that toggling the inspector open
and closed leaves the row's width unchanged — the property the overflowing
measurement broke.
