---
name: "Plugin version coupling"
description: "Casper's requiredPluginVersion and the casper-skills repo version drift independently, benignly upward"
type: project
---

# Plugin version coupling

The plugin's version is declared in the separate `casper-skills` repository
(manifest, marketplace entry, `package.json`, and the opencode plugin file's
`CASPER_PLUGIN_VERSION` constant, which a test keeps in agreement). Casper
hard-codes the version it expects in a single constant in `CasperCore`.

**Nothing mechanically ties the two repositories together**, and both sides
have agreed neither enforces the other's version. The comparison rule
(`installed < required`, never equality) and the legacy-id exception are in
`.superpowers/themes/cli-agents.md` § Agent integration detection.

**How to apply:** bumping Casper's constant on a plugin release is a
nice-to-have, not a release blocker. Never switch the comparison to equality.
See [[agent-integration-policy]].
