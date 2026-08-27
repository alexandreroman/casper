---
name: "SF Symbols need a shared width slot"
description: "SF Symbols have no common intrinsic width, so a column of icon+label rows needs one fixed-width glyph slot or the titles go ragged-left"
type: reference
---

# SF Symbols need a shared width slot

SF Symbols carry **no common intrinsic width**. A row laid out as
`HStack { Image(systemName:); Text(title) }` therefore starts its title at a
different x for every symbol, and a column of such rows reads ragged-left. The
spread is small enough to miss while writing the code and obvious on screen.

Measured with an `NSHostingView` + `fittingSize` probe on a bare
`Image(systemName:)`:

| Symbol                     | `.body` | `.footnote` | `.footnote` + `.small` |
| -------------------------- | ------- | ----------- | ---------------------- |
| `folder.badge.plus`        | 18      | 14          | 11                     |
| `exclamationmark.triangle` | 16      | 13          | 11                     |
| `plus`                     | 15      | 11          | 9                      |
| `xmark`                    | 15      | 10          | 9                      |
| `info.circle`              | 15      | 12          | 10                     |

`NSImage(systemSymbolName:)` under an `NSImage.SymbolConfiguration` of the
same point size reports slightly different numbers (`folder.badge.plus` is
20 pt at 13 pt), so measure the **SwiftUI** `Image` when the view under repair
is SwiftUI.

**How to apply:** give every glyph in one visual column a single
`.frame(width:, alignment: .center)` sized to the widest symbol the column can
show, and hang that width off whatever type the rows already share — for the
sidebar's action rows that is `SidebarActionButtonStyle.iconSlotWidth`.
Wrapping a bare `Image` this way is the safe case of
[[fixed-frame-swallows-inner-padding]]: there is no inner padding to swallow,
and a width-only frame leaves the row's own vertical padding alone.

Pick the width by measuring, never by eye, and re-measure when a symbol is
added: the frame reports its own width whatever it contains, so an undersized
slot lets the glyph overhang into the title with every alignment assertion
still green. A test pins both halves — equal row widths across symbols, and each
symbol's intrinsic width within the slot (`SidebarIconSlotTests`).

A control that stands alone at the trailing edge — the reminder rows' `xmark`
dismiss button — is outside the leading column and takes no slot; padding it
to the column width only pushes it off the edge.
