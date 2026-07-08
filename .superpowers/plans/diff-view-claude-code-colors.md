# Diff View: Match Claude Code's Colors — Design

**Date:** 2026-07-07
**Status:** Done — shipped (HighlightSwift + `DiffHighlighter.swift` merged)
**Scope:** Restyle `DiffSurfaceView`'s line rendering so it visually matches the
reference screenshot of Claude Code's own diff rendering — full-bleed saturated
row backgrounds, a tinted `+`/`-` prefix and line number, and a single
line-number column — while keeping Casper's existing syntax highlighting on
the code text itself.

## Problem

Casper's current diff row styling (`DiffLineStyle.swift`) uses a thin 3px
accent stripe plus a very faint row wash (`tint.opacity(0.18)` over the window
background) and neutral-colored line numbers. The user wants the look of
Claude Code's own diff rendering instead: strongly saturated dark green/red
row backgrounds, a colored `+`/`-` prefix, and a colored line number — while
Casper keeps its syntax-highlighted code text (Claude Code's own rendering has
no syntax highlighting to preserve; Casper's does and keeps it).

Reference colors, sampled by pixel from the user-supplied screenshot:

| Element                       | Hex       |
|--------------------------------|-----------|
| Deletion row background        | `#300B03` |
| Addition row background        | `#152606` |
| Deletion text/accent tint      | `#B96A5E` |
| Addition text/accent tint      | `#87C163` |

The screenshot also shows a single line-number column (not two side-by-side
old/new columns as Casper has today): `27, 28, 29, 30, 30, 31, ...` — the same
number appears twice at a deletion+addition pair because it's the old file's
line 30 and the new file's line 30 respectively.

## Goals

- Row backgrounds for `+`/`-` lines become solid, saturated colors matching
  the sampled hexes above (not a low-opacity wash).
- The accent tint colors (`insertionTint`/`deletionTint`) are updated to the
  sampled text/accent hexes; they continue to drive the left accent stripe and
  the header's `+N`/`−N` stat badges.
- The `+`/`-` prefix character is tinted with the accent color, in both the
  syntax-highlighted and plain-text-fallback code paths.
- The line number is tinted with the accent color on `+`/`-` lines; it stays
  `.tertiary` (gray) on context lines.
- The gutter collapses to a single line-number column: `oldLineNumber` for a
  deletion, `newLineNumber` for an addition or context line — matching the
  dispatch already used by `DiffFileView.highlightedLine(for:)`.

## Non-Goals

- Syntax highlighting on the code text is untouched — HighlightSwift's colors
  keep rendering exactly as they do today. Only the background, prefix, and
  line number change.
- The left accent stripe is kept (Claude Code's own rendering has none, but
  the user chose to keep it as an extra visual cue).
- Light-mode diff colors are out of scope. `AppDelegate.swift:23` already
  forces `NSAppearance(named: .darkAqua)` for the whole app, so the styling
  target is dark-only. `DiffLineStyle.swift`'s doc comments, which currently
  describe an adaptive light/dark wash, will be corrected to say so — no
  runtime behavior changes from this, since the app was already dark-only.

## Design

### `DiffLineStyle.swift`

- `insertionTint` → `Color(red: 0.529, green: 0.757, blue: 0.388)` (`#87C163`).
- `deletionTint` → `Color(red: 0.725, green: 0.416, blue: 0.369)` (`#B96A5E`).
- `background(for:)` returns fixed solid colors instead of
  `tint.opacity(0.18)`:
  - `.addition` → `Color(red: 0.082, green: 0.149, blue: 0.024)` (`#152606`)
  - `.deletion` → `Color(red: 0.188, green: 0.043, blue: 0.012)` (`#300B03`)
  - `.context` → `Color.clear` (unchanged)
- `accent(for:)` is unchanged in shape (still drives the stripe and badges),
  just picks up the new tint values.
- Doc comments updated to drop the "theme-aware... light washes in light
  mode" framing, since the app is dark-only.

### `DiffSurfaceView.swift` — `DiffLineRow`

- **Gutter**: replace the two independent old/new number columns with one
  right-aligned column showing `line.oldLineNumber` for `.deletion`,
  `line.newLineNumber` for `.addition`/`.context`. `maxDigits` (already
  computed in `DiffFileView`) and `gutterWidth` shrink accordingly (roughly
  half the current width formula, since there's one number instead of two).
- **Line number color**: `.tertiary` on `.context`; `DiffLineStyle.accent(for:
  line.kind)` on `.addition`/`.deletion`.
- **Prefix tinting**:
  - Syntax-highlighted path (`highlightedContent`): the prepended prefix
    `AttributedString` gets an explicit `.foregroundColor` attribute set to
    `DiffLineStyle.accent(for: line.kind)` before the highlighted runs (which
    keep their own syntax colors) are appended.
  - Plain-text fallback path (`codeText`'s `else` branch): split the single
    `Text(prefix + content)` into two concatenated `Text` views —
    `Text(prefix).foregroundStyle(accent) + Text(content).foregroundStyle(.primary)`.

### Unaffected

- `DiffFileView.highlightedLine(for:)` and the header's `+N`/`−N` badges
  (already consume `insertionTint`/`deletionTint`, so they pick up the new
  hues automatically).
- `visibleHunks`, truncation, scrolling, highlighting pipeline — no changes.

## Testing

- `DiffLineStyleTests` (if present) or a new test asserting the background
  colors and tints match the new constants.
- Manual verification via `make dev`: open a workspace with staged
  additions/deletions/context lines and confirm the single-column gutter,
  tinted numbers/prefixes, and solid row backgrounds render as expected in
  both a small and a large diff.
