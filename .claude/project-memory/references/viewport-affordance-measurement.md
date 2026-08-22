---
name: "Measuring a TUI agent's viewport affordance"
description: "A raw PTY capture cannot be grepped for viewport text; replay it into a grid, because TUIs redraw cell runs split across escape sequences"
type: reference
---

# Measuring a TUI agent's viewport affordance

Detection reads what libghostty's **grid** holds, not the byte stream that
produced it, so a viewport needle must be measured from a replayed grid.
Grepping a raw `script` capture answers a different question and answers it
wrongly: a TUI redraws only the cells that changed, so a phrase standing on
screen arrives as several cursor-addressed runs. opencode's running-turn footer
`esc interrupt` reaches the PTY as `ESC[23;14H` + `esc ` , `ESC[23;18H` + `in`,
`ESC[23;21H` + `errupt` — three writes, one skipped column whose `t` was left
from an earlier frame. `grep 'esc interrupt'` over that capture matches nothing
at all, and reports an agent as publishing no affordance when it publishes one.

OSC sequences are exempt: they are contiguous, so the raw-file grep for
`ESC]9;4;` and `ESC]0;` in [[agent-state-working-signal]] stays the right tool
for the progress report and the title.

**Why:** a needle that never matches yields silent `idle` forever, and the
mistake is invisible — the capture is real, the grep is clean, and the
conclusion ("this agent publishes nothing") looks measured.

**How to access:** capture with
`(sleep 4; printf '<prompt>\r'; sleep 30; printf '\x03') | TERM_PROGRAM=ghostty
TERM_PROGRAM_VERSION=1.3.1 script -q out.raw <agent>`, then replay `out.raw`
through a ~60-line Python VT interpreter — honour `CUP`/`ED`/`EL` and printable
runs, ignore SGR — and print the grid. Truncate the capture at a byte offset
inside the turn to see a mid-turn frame; `str.find` on the decoded text yields
**character** offsets, so slice the `bytes` object with a byte offset or the
frame lands somewhere else. Live-verify the conclusion in the app afterwards
(`casper debug read-text` next to `dump-state`'s `agentState`) — see the
`debug-casper` skill and [[e2e-surface-creation-flakiness]].
