---
name: "Codex detection caveats"
description: "Codex probe is documentation-derived; ~/.codex/hooks.json is never a Codex marker; hooks need /hooks trust"
type: reference
---

# Codex detection caveats

Three facts about detecting the Casper integration for OpenAI Codex CLI, none of
them discoverable from this repository alone.

**The install layout is documentation-derived and unverified.** Codex installs
are documented to land in
`~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/`, so the version comes
from the path segment. No Codex install has ever been available to confirm this
against, on either the app or the plugin side.

**The probe must read no plugin manifest.** The `casper-skills` repository ships
only `.claude-plugin/plugin.json` and relies on Codex's manifest discovery order
(`plugin.json` → `.codex-plugin/plugin.json` → `.claude-plugin/plugin.json`)
falling through to it. Probing by manifest filename matches nothing.

**`~/.codex/hooks.json` is never evidence of anything, and no code reads it.**
The file appears on machines with **no Codex installed at all** — unrelated
tools write to it (on this machine, a tool called superset, with
`SessionStart`/`UserPromptSubmit`/`Stop` entries pointing at its own script).
Nor does it hold a Casper marker to look for: the `casper-skills` plugin never
writes to it. Anyone reaching for this file as a Codex-presence or integration
signal gets a confident false positive.

**Codex hooks are inert until trusted.** Codex hashes non-managed command hooks
and requires approval via `/hooks` in its TUI, so an install can be complete on
disk and still do nothing. A disk probe cannot observe trust state, so the UI
always states the caveat rather than guessing.

**Why:** an unverified path silently reporting "missing" for users who do have
the integration is the failure mode here, and the manifest and `hooks.json`
traps both produce confidently wrong answers.

**How to access:** confirm the cache path against a real `codex plugin add`
whenever a Codex install becomes available; `codex plugin list --json` (v0.137+)
is a stricter cross-check than globbing. See [[agent-integration-policy]].
