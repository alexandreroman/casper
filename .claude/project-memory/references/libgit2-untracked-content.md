---
name: "libgit2 untracked diff content flag"
description: "GIT_DIFF_SHOW_UNTRACKED_CONTENT is required or untracked text files diff with zero hunks and misflag as binary"
type: reference
---

# libgit2 untracked diff content flag

`diffWorkdirToHead()` in `Sources/CasperGit/Repository.swift` must include
`GIT_DIFF_SHOW_UNTRACKED_CONTENT` in the diff options, alongside
`GIT_DIFF_INCLUDE_UNTRACKED` and `GIT_DIFF_RECURSE_UNTRACKED_DIRS`.

**Why:** without `GIT_DIFF_SHOW_UNTRACKED_CONTENT`, libgit2 lists untracked
files as deltas but emits **zero content hunks** for them — for text *and*
binary alike. The binary-fallback heuristic in `buildFile(...)`
(`hunkCount == 0 && isAdded && new_file.size > 0`) then misclassifies every
non-empty untracked *text* file as binary (rendered as "Binary file"), and the
`GitDiff.insertions`/`deletions` counts — which sum lines across hunks — silently
undercount by ignoring all untracked additions (so the workspace title diff
badge is wrong too). With the flag set, untracked text diffs into real addition
hunks while untracked *binary* still yields zero hunks, so the fallback heuristic
keeps flagging binary correctly and must stay in place.

**How to access:** the flag lives in `options.flags` in `diffWorkdirToHead()`.
Regression coverage is in `Tests/CasperGitTests/DiffTests.swift`:
`testUntrackedFileIsAddedWithAdditions` asserts an untracked text file is not
binary and carries real content lines (a vacuous `allSatisfy` on an empty array
hid this before), and `testBinaryFileHasNoHunks` guards that untracked binary
stays flagged. See also [[libgit2-swift-interop]].
