---
name: "libghostty stale prompt on resize"
description: "The pinned libghostty leaves stale prompts on a column resize; the fix awaits a fork build"
type: project
---

# libghostty stale prompt on resize

The pinned libghostty (libghostty-spm `1d84cf6…`, upstream Ghostty
`042b16b`, shipped in Casper 0.4.0) leaves stale copies of a shell prompt on
screen when a terminal's column count changes: dragging a split divider with a
Powerlevel10k prompt (OSC 133 marks, a full-width first line) stacks one
leftover first line per intermediate size. Casper 0.3.0 (upstream Ghostty
v1.3.1) is unaffected.

- **Cause, upstream:** `Screen.resize` clears the prompt for the shell's
  SIGWINCH redraw *after* the column reflow (upstream `dde3d4d6b` and
  `a3c1caba5`, 2026-07-17), and reflow copies a row's `.prompt` mark onto every
  row it splits that line into, so the clear starts too low and leaves the top
  of the prompt.
- **Fix, upstream:** ghostty-org/ghostty `8ad3f607f` ("terminal: prompt redraw
  on resize no longer leaves stale prompts", PR #15199, 2026-11-11).
- **Blocker, fork:** as of 2026-11-16 no libghostty-spm release includes it.
  The fork's upstream bump to `d4cf6ec` fails to build because its patch
  `0015-hold-frame-for-prompt-redraw.sh` anchors on `Screen.zig` text that
  `8ad3f607f` rewrites.
- **No Casper-side workaround:** libghostty owns the reflow and the PTY, and
  every fork build older than the regression lacks the clipboard API
  CasperGhostty uses (upstream, 2026-08-24).
- **Regression test:** `SplitResizePromptE2ETests` is a strict
  `XCTExpectFailure` until the pin carries the fix.

**Why:** a user-reported regression whose fix lies outside this repository;
the decision is to wait for a fork release rather than self-build or roll the
pin back.

**How to apply:** when touching the libghostty pin, or when asked whether this
regression is fixed, check for a libghostty-spm release built from an upstream
commit that contains `8ad3f607f`
(`gh release list -R Lakr233/libghostty-spm`; the release body names the
upstream sha; `git merge-base --is-ancestor 8ad3f607f <sha>` in a Ghostty
clone). Bump to it per [[ghosttykit-pin]], drop the `XCTExpectFailure` (the
strict expectation fails on its own once the bug is gone), add a `Fixed`
CHANGELOG entry, and delete this note.
