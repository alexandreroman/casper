---
name: "Agent-state working signal lives in the OSC title"
description: "Claude Code signals working via its OSC terminal title (Braille spinner); the pinned libghostty fork forwards titles intact"
type: reference
---

# Agent-state working signal lives in the OSC title

Current Claude Code encodes its live run-state in the **OSC terminal title**,
not in the visible viewport: a leading **Braille spinner glyph** (any scalar in
`U+2800…U+28FF`) while a turn runs, reverting to a leading `✳` (`U+2733`) at
rest. Current Claude Code emits no `esc to interrupt` viewport hint; Casper
carries a matcher for it only as a resilience fallback. Casper's detection
therefore reads the title via `GHOSTTY_ACTION_SET_TITLE` → `readOSCTitle()` and
classifies it in `AgentDetectionRuleSet.signal(fromTitle:)`.

Two durable facts behind this:

- **The pinned libghostty-spm fork forwards OSC title sequences intact**
  (verified end-to-end). This is a capability boundary worth remembering: the
  same fork does NOT honor a surface's `command` at spawn (see
  [[ghosttykit-pin]]), so "it's a sandbox fork, assume it strips things" is
  wrong for titles — OSC 0/1/2 titles come through as `SET_TITLE` actions.
- **Detection is version-coupled to Claude Code's terminal UI**, which has
  already changed once (viewport interrupt-hint → OSC-title spinner). Expect the
  markers to drift across Claude Code releases; the viewport `blocked` matcher
  (`do you want to proceed?` + `esc to cancel`) is likewise version-sensitive.

**Why:** when the working icon stops lighting up (or blocked/idle misfire), the
first suspect is a Claude Code UI change, not a Casper regression.

**How to access:** re-verify against a live *working* Claude Code — read its
actual OSC title and viewport (in a Casper terminal, temporarily log the
`SET_TITLE` action; or inspect any terminal host that exposes the title). Update
the scalar ranges / substrings in `AgentDetectionRuleSet.claudeCode`
accordingly. Live-verify the GUI under session `dev` (see [[app-sessions]]).
