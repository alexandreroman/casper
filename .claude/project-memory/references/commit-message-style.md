---
name: commit-message-style
description: Casper commit message format — verb + action performed
type: feedback
---

# commit-message-style

Commit messages for the Casper project must follow the format **verb + action
performed**, and must **always be written in English** (subject AND body), e.g.
"Simplify hook parsing", "Add the port allocator".

**Why:** a consistent, English, verb-first subject is a project-wide convention.

**How to apply:** Write the commit subject as an English verb followed by the
action that was done. Keep it concise; write the whole message in English.
Applies on top of the existing git workflow ([[git-workflow]]): still get
authorization before committing/pushing.
