---
name: "Project memory file naming"
description: "Do not prefix project-memory filenames with 'casper'"
type: feedback
---

# Project memory file naming

Do not prefix project-memory reference filenames (or their `name:` slug) with
`casper`. Name files by what they describe (e.g. `repo-config.md`,
`gui-synthetic-input.md`), not `casper-*`.

**Why:** the whole project is Casper, so a `casper` prefix is redundant noise in
every filename.

**How to apply:** when creating a memory under
`.claude/project-memory/references/`, drop any leading `casper-`; match the
existing unprefixed naming of the other reference files.
