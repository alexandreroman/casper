---
name: "Agent integration policy"
description: "Casper detects and reminds about agent integrations; it never writes another tool's config"
type: project
---

# Agent integration policy

Casper supports three coding agents — Claude Code, OpenAI Codex CLI, and
opencode — and only detects and reminds about their Casper integration; it never
writes another tool's configuration. The design (the global probe, its three
layers, the reminder rows) is in `.superpowers/themes/cli-agents.md` § Agent
integration detection.

pi is out of scope: it ships neither a permission system nor a todo tool, so
`blocked` and `progress` have nothing to map onto.

Every Casper surface — agent state, progress bar, notifications, info panel —
works on all three agents. There is no capability gap to represent in the UI.

**Why:** writing another tool's config makes Casper responsible for a file it
does not own and cannot safely migrate; detection is honest and reversible.

The probe resolves the three agent CLIs through `LoginShellPath`, whose cold
probe cost is the price of a correct answer, not an inefficiency to trim — see
[[shell-path-resolution]].

**How to apply:** when adding an agent, extend the probe and the reminder only.
Do not add install or repair actions that mutate an agent's config. See
[[codex-detection-caveats]] and [[plugin-version-coupling]].
