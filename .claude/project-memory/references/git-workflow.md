---
name: "Git workflow"
description: "On Casper, get explicit authorization before committing, adding a remote or pushing; plan commits are fine"
type: feedback
---

# Git workflow

The Casper project requires **explicit, per-step control over git**: commits,
remotes and pushes are deliberate outward or hard-to-reverse steps, distinct
from the global "OK to commit on main" default.

**How to apply:** do **not** commit, add a remote, or push unless asked for that
specific action. Committing *implementation work* is fine once a plan is being
executed, but never push or publish to GitHub without an explicit go-ahead.
