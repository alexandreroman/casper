---
name: "Cross-session provenance"
description: "Treat each peer Claude session as a distinct voice; ask which worktree before accepting a state description"
type: feedback
---

# Cross-session provenance

Casper work routinely involves peer Claude sessions in sibling repositories
and in several worktrees of the same repository. Two sessions can describe
"the plugin repo" at the same moment and both be correct, because each is
looking at a different worktree or branch.

Track the **sender identity** of every cross-session message (the socket and
session name), never a mental category such as "the plugin session". Before
accepting any description of repository state — commit counts, branch names,
what a file contains — establish **which worktree** it describes. A session
whose worktree has since been deleted can still have been exactly right at
the time it spoke.

Any claim that shapes code must be verified against the files directly, not
carried on a peer's report, however reliable that peer has proven.

**Why:** conflating two senders produced a confident, wrong account of a
repository's state, and the appearance of a contradiction where there was
none — two truthful snapshots of two branches, one later merged into the
other. The constants themselves were sound only because they had been read
from the files independently.

**How to apply:** quote the sender when relaying a peer's claim. Ask "which
worktree?" before acting on state. Re-read the file when a claim decides an
identifier, a path, or a comparison. See [[agent-integration-policy]].
