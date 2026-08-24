---
name: "Codex detection caveats"
description: "Codex cache layout confirmed; hook trust lives in config.toml [hooks.state]; ~/.codex/hooks.json is never a Codex marker"
type: reference
---

# Codex detection caveats

Four facts about detecting the Casper integration for OpenAI Codex CLI, none of
them discoverable from this repository alone.

**The install layout is confirmed.** Codex installs land in
`~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/`, so the version comes
from the path segment. Verified against a real install (Codex 0.149.0):
`~/.codex/plugins/cache/casper/casper/0.2.0/`, with
`codex plugin list --json` reporting `"pluginId": "casper@casper"`,
`"version": "0.2.0"`, `"installed": true`, `"enabled": true`.

**`codex plugin list --json` is the stricter cross-check**, and exposes exactly
these fields: `pluginId`, `name`, `marketplaceName`, `version`, `installed`,
`enabled`, `source`, `marketplaceSource`, `installPolicy`, `authPolicy`. There
is **no hook-trust field** among them, so this command answers "is it
installed", never "is it approved". Its stdout can also carry trailing terminal
escape bytes when a user's shell wraps `codex` in a function, so parse the first
JSON document rather than the whole stream.

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

## Hook trust is readable from `config.toml`

Codex hashes non-managed command hooks and refuses to run them until the user
approves them through `/hooks` in its TUI, so an install can be complete on disk
and still do nothing. That approval is **recorded on disk**, in
`~/.codex/config.toml` under `[hooks.state]`, one table per hook:

```toml
[hooks.state."casper@casper:hooks/hooks.json:session_start:0:0"]
trusted_hash = "sha256:63ef580c6830…"
enabled = true
```

The key is `"<pluginId>:<hooks file>:<event>:<index>:<index>"`, so Casper's
entries are the ones prefixed `casper@casper:` — matching
`AgentIntegration.pluginID`. `enabled` is present only on some entries; its
absence means enabled. Non-plugin hooks use an absolute path in place of the
plugin id (`"/Users/alex/.codex/hooks.json:stop:0:0"`).

Presence of a `trusted_hash` for `casper@casper:` means the user has been
through `/hooks`. Casper does **not** recompute the hash — that would require
reproducing Codex's hashing scheme — so a plugin update that invalidates a
stored hash reads as trusted while Codex re-prompts. That false negative is
deliberate: it is quieter than the alternative of asserting a trust problem that
usually does not exist.

**Why:** an unverified path silently reporting "missing" for users who do have
the integration is one failure mode; the other is a permanent, unresolvable
notice shown to every user whose hooks are in fact approved. The manifest and
`hooks.json` traps both produce confidently wrong answers.

**How to access:** read `[hooks.state]` from `~/.codex/config.toml`, the same
file the probe already reads for the disabled check; use
`codex plugin list --json` to confirm install and version. See
[[agent-integration-policy]] and [[plugin-version-coupling]].
