---
name: "Markdown block spacing is one-sided"
description: "MarkdownAttributedString's block-to-block gap comes from paragraphSpacingBefore on the following block only; a block whose own paragraph is bordered takes that gap as a dedicated spacer paragraph instead"
type: reference
---

# Markdown block spacing is one-sided

`MarkdownAttributedString` gives every block-to-block gap (paragraph, heading,
list, table, code block, block quote, thematic break) from exactly one
constant, `Layout.blockSpacingBefore`, applied as the *following* block's own
`paragraphSpacingBefore`. Nothing in the file sets a nonzero `paragraphSpacing`
("after") at all. TextKit adds a paragraph's own `paragraphSpacing` and the
next paragraph's `paragraphSpacingBefore` — setting both sides of a transition
made the realized gap depend on which two block kinds happened to be adjacent
(some pairs doubled the gap, some canceled it to nothing, confirmed by a
screenshot of the running app: a paragraph touching a table's top border with
no visible gap, next to a thematic-break rule with a doubled gap below it).
Three deliberate exceptions to the single value: a heading's own leading gap
is larger (`Layout.headingSpacingBefore`); a list item after the first is
tighter (`Layout.listItemSpacingBefore`); the document's first block gets none
of it at all (`Builder.build`'s `isFirstBlock`).

## A bordered block's gap is a paragraph, not a spacing value

A block whose own paragraph carries `.textBlocks` — a block quote's bar
(`blockQuoteRule`, on `renderBlockQuote` and the quoted branch of
`renderListItem`) and a GFM table's header row (`renderTableCell`) — cannot
express its leading gap as a spacing attribute at all. Two mechanisms were
each measured to realize **0 pt** of the 12 pt they asked for:

- **`paragraphSpacingBefore` on the bordered paragraph itself.** TextKit folds
  it into the very `layoutFragmentFrame` the `NSTextTableBlock` border wraps,
  so the border box grows upwards over the gap instead of space opening above
  it. Measured on a laid-out TextKit 2 stack: the table's border edge sat at
  the exact `y` the preceding paragraph's last line ended at, with the 12 pt
  inside the border.
- **`paragraphSpacing` on the `"\n"` that joins the two blocks.** A paragraph
  is delimited by newline *characters*, not by attribute runs, so that `"\n"`
  is the last character of the *preceding* block's paragraph — whose style
  TextKit resolves from its **first** character. The style set on the
  separator is simply never read.

The working mechanism (`Builder.separator`, keyed off `Block.hasBlockQuoteRule`
and `Block.opensTableBorder(after:)`) emits the gap as real occupied height:
the separator becomes `"\n\n"`, whose second newline is a paragraph of its own
carrying a tiny font (`Layout.spacerFontSize`) and `minimumLineHeight ==
maximumLineHeight == gap`. Being its own unbordered paragraph, it sits outside
the following block's border box. The table case compares table identities so
only the transition *into* a table gets a spacer — a gap ahead of each header
cell would push the row's cells onto separate lines.

`Layout.blockQuoteIndent` is deliberately narrow (6) so the gap between the bar
and the text it marks reads as one unit rather than two unrelated elements.

Two `> ` quotes separated by a blank line are two distinct `Block`s, each with
its own fresh `NSTextTable`/`NSTextTableBlock` from `blockQuoteRule()` — so
they draw two independent bars, and the standard gap between them is what keeps
those bars from reading as one continuous bar.

`MarkdownAttributedStringTests`
`testEveryBlockToBlockGapIsTheSameRealizedValue` pins all of this on laid-out
geometry rather than on style values, because a style-value assertion passes
under both collapsing mechanisms above.
