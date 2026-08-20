---
name: "Plugin version coupling"
description: "Casper's requiredPluginVersion and the casper-agents repo version drift independently, benignly upward"
type: project
---

# Plugin version coupling

The plugin's version is declared in the separate `casper-agents` repository
(manifest, marketplace entry, `package.json`, and the opencode plugin file's
`CASPER_PLUGIN_VERSION` constant, which a test keeps in agreement). Casper
hard-codes the version it expects in a single constant in `CasperCore`.

**Nothing mechanically ties the two repositories together.** The comparison is
`installed < required ⇒ outdated`, so drift is benign in one direction only: a
user ahead of Casper's build reads as current, while the constant only ever
catches users who are *behind*.

**Why:** strict equality would give a false "outdated" to anyone ahead of
Casper's build, and would make every plugin release require a Casper release
just to stop the nagging. Both sides have agreed neither enforces the other's
version.

**How to apply:** bumping Casper's constant on a plugin release is a
nice-to-have, not a release blocker. Never switch the comparison to equality.
See [[agent-integration-policy]].
