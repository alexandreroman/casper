---
name: "Markdown table columns align by display width"
description: "An emoji cell is two columns wide; the two table checkers conflict"
type: feedback
---

# Markdown table columns align by display width

Pad Markdown table cells so the columns line up by **display width**, not by
character count. `✅` is one character but occupies two columns, so its cell
carries one space fewer than a `◐` cell of the same visual width.

**Why:** two checkers are available and they are mutually exclusive on any cell
holding a wide character.

- **markdownlint `MD060` (`table-column-style: aligned`)** measures display
  columns, and is the rule that matches what a Markdown viewer actually
  renders. This repo carries no `.markdownlint*` config of its own, so it
  applies only where an editor supplies markdownlint diagnostics.
- **`check_tables.py`**, shipped under `scripts/` in the skillbox
  `general-rules` skill, compares character counts and reports an emoji row as
  one column short of its header.

Display width wins: a reader sees rendered columns, not code points. A
`check_tables.py` report of `col widths [38, 7, 70] (expected [38, 8, 70])` on
an emoji row is therefore the expected output, not a defect — the script exits
0 and only prints.

Two documents set the precedent: `.superpowers/status.md` § At a glance, and
the signal table in `.superpowers/themes/agent-state-detection.md`, whose cells
carry the spinner glyphs `◐◑` and `✳`. Both pad by display width.

**How to apply:** measure with `unicodedata.east_asian_width`, counting `W` and
`F` as 2:

```bash
python3 -c "
import unicodedata
def w(s): return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s)
for i, l in enumerate(open('FILE', encoding='utf-8'), 1):
    l = l.rstrip('\n')
    if l.startswith('|'): print(i, [w(c) for c in l.split('|')[1:-1]])
"
```

Every row of one table, separator included, must print the same widths. This is
the same characters-versus-bytes trap as [[line-width-in-characters]], one level
further in: there, display columns and characters agree; here they do not.
