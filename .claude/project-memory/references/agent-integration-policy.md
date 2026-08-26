---
name: "Agent integration policy"
description: "Casper detects and reminds about agent integrations; it never writes another tool's config"
type: project
---

# Agent integration policy

Casper supports three coding agents — Claude Code, OpenAI Codex CLI, and
opencode — and **never writes into another tool's configuration**. Each agent's
own installer installs the Casper integration; Casper's role is limited to
*detecting* whether that integration is present and current, and surfacing a
non-modal, dismissible reminder in the sidebar footer.

The detection probe is **global** (evaluated once for the spaces view), not per
workspace, so it needs no per-agent OSC-title rules. An agent whose CLI is
absent renders nothing at all — a reminder never appears for an agent the user
does not have.

pi is out of scope: it ships neither a permission system nor a todo tool, so
`blocked` and `progress` have nothing to map onto.

Every Casper surface — agent state, progress bar, notifications, info panel —
works on all three agents. There is no capability gap to represent in the UI.

**Why:** writing another tool's config makes Casper responsible for a file it
does not own and cannot safely migrate; detection is honest and reversible. The
global probe answers "the user has Codex but not the integration", which is a
property of the machine, not of any one workspace.

The probe resolves the three agent CLIs through `LoginShellPath`, whose shell
`PATH` lookup is deliberately **interactive as well as login**. That is the
price of a correct answer, not an inefficiency to trim — see
[[shell-path-resolution]] for why a login-only shell cannot see the `PATH` the
user has in a terminal.

**How to apply:** when adding an agent, extend the probe and the reminder only.
Do not add install or repair actions that mutate an agent's config. See
[[codex-detection-caveats]] and [[plugin-version-coupling]].
