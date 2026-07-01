---
name: git-workflow
description: "On Casper, get explicit authorization before git init/commit/push; commit identity"
type: feedback
---

# git-workflow

On the Casper project the user wants **explicit, per-step control over git**:
during setup they repeatedly gated actions ("n'initialise rien", "git init
seulement", "crée un commit vide", "prépare sans pousser").

**Why:** they treat repo creation/commits/pushes as deliberate outward or
hard-to-reverse steps, distinct from the global "OK to commit on main" default.

**How to apply:** do **not** `git init`, commit, add a remote, or push unless the
user asks for that specific action. It is fine to commit *implementation work*
once they've said to execute a plan, but never create the repo, push, or publish
to GitHub without explicit go-ahead. Commits use **alexandre.roman@gmail.com**
(set as local `user.email`). The repo is currently local-only, unpushed. See
[[project]].
