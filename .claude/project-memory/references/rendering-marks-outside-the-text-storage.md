---
name: "Rendering-only marks belong outside the text storage"
description: "In a selectable text view, marks that are rendering rather than content (the diff's +/- cue, line numbers) go in the ruler/gutter, never prefixed into the text"
type: feedback
---

# Rendering-only marks belong outside the text storage

In a selectable Casper text view, a mark that is rendering rather than content —
the diff's `+`/`-` cue, a line number — belongs in the gutter (an `NSRulerView`)
or in some other drawn chrome. It is never prefixed into the text storage, even
when it reads like the line's first character.

**Why:** a mark inside the text is inside everything the text view does with
text, and each consequence has to be fought separately. It lands in the selection
highlight, which tells the reader they grabbed it. It lands on the pasteboard, so
a pasted diff no longer compiles. And it indents only the **first** display row
of a wrapped line, since the continuation rows carry no mark — the code's leading
edge then depends on whether a row happens to start a line. Stripping the mark
back out on the way to the pasteboard fixes just the third-hand symptom, and the
carve-it-out-of-the-selection variant costs a `setSelectedRanges` override,
discontiguous ranges, caret special cases, and a layout-cost guard for ⌘A. Moving
the mark out deletes all of it: `NSTextView`'s own selection and copy behaviour
is then correct untouched.

**How to apply:** keep the document model emitting source text only, and draw the
mark in `drawHashMarksAndLabels(in:)` positioned from the shared fragment
geometry — once per line, on the row where the line starts, not once per display
row. Add its column to `ruleThickness` rather than to the code column, so the
code starts at the same `x` on every row. Round a font-measured column width
**up**: a fractional `ruleThickness` leaves the ruler's trailing pixel only
partly covered by the row tint, which shows as a seam and reads as stray ink to a
pixel probe (see [[nsrulerview-unclipped-drawing]] for the other way ruler
drawing surprises you). Commentary that warns the reader about the text itself is
the exception and stays in the text — the diff keeps its `… (line truncated)`
marker, being the only sign that a copy of that line is a prefix of the real one.
