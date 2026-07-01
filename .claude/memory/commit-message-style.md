---
name: commit-message-style
description: Casper commit message format — verb + action performed
type: feedback
---

Commit messages for the Casper project must follow the format **verb + action
performed**, and must **always be written in English** (subject AND body), e.g.
"Simplify hook parsing", "Add the port allocator".

**Why:** The user asked for this convention explicitly as a project rule.

**How to apply:** Write the commit subject as an English verb followed by the
action that was done. Keep it concise; write the whole message in English.
Applies on top of the existing git workflow ([[git-workflow]]): still get
authorization before committing/pushing.
