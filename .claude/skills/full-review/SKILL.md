---
name: full-review
description: Use when the user asks for a full or complete code review of the Casper project, a cleanup pass over every module, or to run the full review again.
---

# Full review

Runs a complete review of the repository (simplification, dead code,
accuracy of the docs and memory against the code, cross-module duplication,
workaround cleanup, every recommendation applied). The review instructions
are in `brief.md`, next to this file; this file decides where the review
runs.

No automated UI testing is possible: macOS grants Screen Recording and
Accessibility per app bundle and per requesting process, and neither this
session nor the review instance holds those grants (see the
`agent-visual-verification-limits` memory note). The review proves itself
with the build, the test suite and headless tests; anything only the eye
can confirm becomes a manual check for the user, run through `make dev`.

## Where it runs

- **Casper available** (`$CASPER_WORKSPACE_ID` set and `casper` on the
  `PATH`): delegated to a separate Claude Code instance in a new Casper
  workspace, while this session waits and reports. Follow "Delegated" below.
- **Otherwise**: in the foreground, in this session and this checkout, on
  the current branch: no worktree, no background agent, no `casper` call.
  Read `brief.md` and follow it yourself, in its foreground mode (its
  placeholders stay unfilled).

## Delegated

1. **Base**: `main`, unless the user names another ref. Check it has no
   uncommitted changes that the review should see: the workspace only gets
   committed work.
2. **Prompt file**, outside the repository, with the placeholders filled
   (substitute the chosen ref for `main` if the user named another):

   ```bash
   stamp="$(date +%Y%m%d-%H%M%S)"
   prompt="/tmp/casper-review-$stamp.md"
   done_file="/tmp/casper-review-$stamp.done"
   sed -e "s|{{DONE_FILE}}|$done_file|g" -e "s|{{BASE}}|main|g" \
     .claude/skills/full-review/brief.md > "$prompt"
   ```

3. **Instance**: read the `casper` skill's workspace reference, then create
   a workspace on branch `review-$stamp` that launches Claude Code on the
   prompt. Record the `path` the command prints: it is the review worktree.

   ```bash
   casper workspace new "review-$stamp" --base main \
     --command "claude \"Read the instructions in $prompt and follow them.\""
   ```

4. **Watch**: a background Bash command that ends when the file is written,
   so this session is woken up, plus the sidebar progress bar (see the
   `casper` skill's progress reference), cleared when the file arrives:

   ```bash
   until [ -s "$done_file" ]; do sleep 60; done; sleep 5; cat "$done_file"
   ```

   The review takes hours: the test suite alone runs several times.

5. **When the file arrives**, run `casper notify`, then:
   - first line `DONE`: verify on the review branch
     (`git log main..review-$stamp`, `git -C <worktree> status --porcelain`
     empty, `make -C <worktree> test`), then report to the user: the main
     findings, the doc and memory corrections, the user-visible changes and
     their `CHANGELOG.md` entries, the manual checks to run with `make dev`,
     anything not applied. Do not merge: the user decides.
   - first line `BLOCKED`: tell the user what the instance needs. It waits
     for the answer in its own session.

## Common mistakes

- Passing the brief inline in `--command`: it is retyped as keystrokes, so
  quotes and newlines break. Always go through the prompt file.
- Putting the prompt file inside the repository: it could get committed.
- Without Casper, reaching for a worktree or a background agent: the review
  runs here, in the foreground.
- Reviewing a stale base: merge or commit pending work on `main` first.
- Launching the GUI to check a change (`make dev`, the `debug-casper`
  screenshot or input verbs): the TCC grants are missing, so the capture
  fails or the run hangs on a permission prompt nobody answers. Leave
  visual checks to the user.
