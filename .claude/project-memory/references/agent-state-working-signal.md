---
name: "The working signal is the OSC 9;4 progress report"
description: "Claude Code marks a live turn with OSC 9;4 progress; the OSC title spinner is a secondary, version-coupled signal"
type: reference
---

# The working signal is the OSC 9;4 progress report

Claude Code marks a live turn with a **ConEmu/iTerm2 OSC 9;4 progress
report**: `ESC]9;4;3` (indeterminate) when the turn starts, `ESC]9;4;0`
(remove) when it ends. It emits this inside a Casper terminal because
`TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION=1.3.1` clear its `>= 1.2.0`
gate, and because the `terminalProgressBarEnabled` setting ("Emit OSC 9;4
progress sequences during long operations") defaults on. libghostty decodes
it as `GHOSTTY_ACTION_PROGRESS_REPORT`, which the pinned header already
models (`ghostty_action_progress_report_s`) — reaching it needs no
`make vendor` bump and no fork change.

Casper's detection treats it as the **primary** `working` signal:
`casperGhosttyAction` latches it per-surface into
`GhosttySurfaceView.latestProgressReport`, and
`AgentSignal(progress:)` in `AgentDetection.swift` maps `set`/`indeterminate`
to `working` and `removed`/`error`/`paused` to `absent`.

Two **secondary** signals back it up, both version-coupled to Claude Code's
UI:

- **The OSC title.** Claude Code prefixes it with a spinner glyph while
  working — the quadrant circles `◐◑◒◓` (U+25D0–U+25D3) in 2.1.239, Braille
  (U+2800–U+28FF) in earlier builds; both ranges are matched, and kept
  disjoint. A `✳` (U+2733) prefix marks rest. The pinned libghostty-spm fork
  forwards OSC 0/1/2 title sequences intact as `SET_TITLE` actions — a
  capability boundary worth remembering, since the same fork does NOT honor a
  surface's `command` at spawn (see [[ghosttykit-pin]]).
- **The viewport.** The only source for `blocked`
  (`do you want to proceed?` + `esc to cancel`) and the only `working` source
  for an agent that reports no progress. Claude Code's `esc to interrupt`
  hint survives in the bundle only under the `low_priority_waiting` API-retry
  banner and is never rendered during normal work.

OSC 21337 (`TAB_STATUS`) carries exactly the right payload but is
feature-flagged off — its gate function returns `false` unconditionally — and
the vendored libghostty header does not decode it.

**Why:** when the working icon stops lighting up (or blocked/idle misfire),
the first suspect is a Claude Code UI or protocol change, not a Casper
regression. The title spinner's glyph set has already moved once, which is
why liveness rests on a protocol Claude Code emits deliberately rather than
on its UI chrome.

**How to access:** `casper debug dump-state` reports `agentState` (what
detection concluded, i.e. what the sidebar icon renders), `oscTitle` and
`progressReport` for the exposed surface; `casper debug read-text` gives the
viewport. Together they diagnose a detection failure against the live app
with no temporary logging. To capture what Claude Code actually emits
outside Casper, run it under `script` with `TERM_PROGRAM=ghostty` and
`TERM_PROGRAM_VERSION=1.3.1` and grep the raw file for `ESC]9;4;` and
`ESC]0;`. Update the ranges/substrings in `AgentDetectionRuleSet.claudeCode`
accordingly. Live-verify the GUI under a dev session (see [[app-sessions]]
and the `debug-casper` skill).
