---
name: git-workflow
description: "On Casper, get explicit authorization before git init/commit/push; commit identity"
type: feedback
---

# git-workflow

The Casper project requires **explicit, per-step control over git**: repo
creation, commits, remotes, and pushes are deliberate outward or hard-to-reverse
steps, distinct from the global "OK to commit on main" default.

**How to apply:** do **not** `git init`, commit, add a remote, or push unless
asked for that specific action. Committing *implementation work* is fine once a
plan is being executed, but never create the repo, push, or publish to GitHub
without an explicit go-ahead. Commits use **alexandre.roman@gmail.com** (the
local `user.email`). See [[project]].
