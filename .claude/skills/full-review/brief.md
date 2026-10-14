# Task: full code review of Casper, with every fix applied

Two modes, set by whoever launched you:

- **Delegated**, when the `cat >` command under "Final signal" targets a
  real file under `/tmp`: you run in a dedicated Casper workspace, a Git
  worktree of `casper` on your own branch created from `{{BASE}}`. Work
  autonomously: nobody watches this session in real time. Do NOT merge into
  `main`, do NOT push, and do NOT delete the workspace: the user reviews and
  merges.
- **Foreground**, when that command still shows a placeholder in double
  braces: you run in the user's own checkout, on its current branch, while
  the user follows along. Commit there; never push.

Either way, launching this review is the explicit go-ahead the
`git-workflow` memory note asks for: commit the review's work on this
branch, nothing more (no push, no tag, no release).

## Scope

The whole repository: `Sources/` (every module), `Tests/`, `Scripts/`,
`Makefile`, `Package.swift`, `Packaging/` (plists, appcast template),
`.github/workflows/`, `vendir.yml`, `README.md`, `CHANGELOG.md`,
`CLAUDE.md`, `.superpowers/` (`architecture.md`, `themes/`, `status.md`,
`INDEX.md`; not the gitignored `sdd/`), `.claude/skills/debug-casper/` and
`.claude/project-memory/`.

Leave unchanged: `.claude/skills/full-review/`, `Vendor/` (vendored by
`make vendor`), the app icon sources under `Packaging/AppIcon/`, and
`Package.resolved` (no dependency bump, no new dependency: GhosttyKit stays
pinned).

## No automated UI testing

macOS grants Screen Recording and Accessibility per app bundle and per
requesting process, and this session holds neither (see the
`agent-visual-verification-limits` and `tcc-screen-recording-needs-a-bundle`
memory notes). So:

- Never launch the GUI: no `make dev`, no `Casper-dev.app` or
  `.build/debug/casper` launch, no `casper debug` verb (they need a running
  instance), no `screencapture`, `osascript` or CGEvent input. A permission
  prompt nobody answers stalls the run.
- Prove behaviour headlessly instead: XCTest unit tests, offscreen
  `cacheDisplay(in:to:)` pixel tests for AppKit drawing, `NSHostingView`
  layout tests, the in-process `GhosttySurfaceView` harness (the memory notes
  `headless-swiftui-layout-tests` and `ghostty-real-surface-e2e-harness`
  give the recipes).
- Whatever only the eye can confirm (SwiftUI composition, window chrome,
  toolbar, animations, focus, drag and drop) becomes a **manual check** in
  the final report: what changed, and the exact steps to see it in
  `make dev`.

## Rules

1. **Simplify the code as much as possible and delete dead code**: unused
   types, functions, parameters, properties, enum cases, files, branches,
   test helpers, `Makefile` targets and scripts; stale, duplicated or
   contradicting passages in the docs (`README.md`, `CLAUDE.md`,
   `.superpowers/`, the `debug-casper` skill); stale, duplicated or
   contradicting memory notes and their `MEMORY.md` lines. Two traps: a
   `#if DEBUG` seam only the tests reach is not dead (the suite runs in
   debug), and an import the compiler lets you drop is not necessarily
   unused (see the `unused-import-grep-false-positives` note).
2. **Be rigorous about the accuracy of every document against the code.**
   Check every claim in `.superpowers/` (architecture, themes, status),
   `README.md`, `CLAUDE.md`, the memory notes, the `debug-casper` skill, the
   CLI `--help` texts and the code comments against what the code does.
   `.superpowers/themes/` own the design: when a theme and the code
   disagree, find out which side is intended (the theme, the memory notes,
   `git log`). A deliberate as-built behaviour means fixing the doc; a
   departure from a documented decision means fixing the code. When neither
   source settles it, do not guess: leave both as they are and list the
   question in the final report. Claims about external libraries go against
   a primary source: Ghostty's own macOS source (the reference
   implementation, see `ghostty-is-the-reference`) and the pinned
   `Vendor/ghostty/ghostty.h` for libghostty; the libgit2, Sparkle and Apple
   documentation (context7 or the official sites) for the rest.
3. **Remove code duplicated across modules**: merge helpers, views,
   modifiers, parsing and test fixtures that two or more places repeat, with
   one name and one behaviour, into the module that owns them per
   `.superpowers/architecture.md` § Module boundaries. Never move GhosttyKit
   access out of `CasperGhostty`, libgit2 access out of `CasperGit`, or UI
   into `CasperCore`.
4. **Clean up remaining workarounds**: `TODO` / `FIXME` / `HACK` /
   "workaround" comments, hard-coded delays (`asyncAfter`, sleeps, polling)
   standing in for a missing signal, magic offsets that compensate for
   another bug, per-case exceptions, duplicated fixes. When the root cause
   is in Casper's code, fix it, then delete the workaround and any memory
   note that only documents it. A workaround for a bug in macOS, SwiftUI,
   AppKit, libghostty or libgit2 that a memory note records stays: it cannot
   be proven gone on both macOS 15 and 26 from here. Check only that its
   comment points at the note.
5. **Apply every recommendation** from the review. None is left as a
   "follow-up". If one truly cannot be applied (it would contradict a rule
   of `CLAUDE.md` or a user decision recorded in the project memory, or
   break a contract listed under "Constraints"), say why in the final
   report.

## Constraints

- `CLAUDE.md`, the project memory and `.superpowers/` are the source of
  truth for the conventions: read `CLAUDE.md`, `MEMORY.md` and every note it
  links, `.superpowers/INDEX.md`, `architecture.md` and `status.md` in full
  before starting, and each theme doc before reviewing its area.
- **Behaviour stays identical unless a change is intended.** Every refactor
  keeps `make build` and `make test` green with no new compiler warning
  (the libgit2 linker warning is known and benign). Every intended
  behaviour change (a bug fix, a workaround removal) comes with a test that
  fails before it and passes after, written TDD by the code-writer.
- **Contracts stay unchanged**: the `casper` CLI subcommands, flags, JSON
  output and exit codes; the control-channel and debug-channel verbs; the
  `CASPER_*` environment variables; the `session.json` encoding (byte-stable,
  and existing files must still decode); the `.casper.json` schema. The
  agent plugins in `/Users/alex/Projects/personal/casper-skills` depend on
  them (read it to check what they rely on; never modify it). A contract
  bug goes in the final report, not into a silent fix.
- `#if DEBUG` gating stays intact: the debug channel and verbose logging
  never reach a release build, so `make release` must still compile.
- Every user-visible change adds an entry under `## [Unreleased]` in
  `CHANGELOG.md`, in the same commit. Refactors, tests and documentation get
  none. Every behaviour change updates its theme doc, and `status.md` when
  it changes what is built.
- Line length: Markdown 80 columns, code 120. Commit messages in English, a
  verb + action subject (see the `english-only` note).
- Follow `CLAUDE.md`: delegate every code change to the
  **skillbox:code-writer** agent, following the `implementation-workflow`
  note (one code-writer per task, a review between tasks, a commit per
  task); persist and prune memory with the **skillbox:project-memory**
  skill.

## Process

1. **Toolchain**: `xcode-select -p` must point into `Xcode.app` (the
   Command Line Tools cannot link XCTest), and `brew list libgit2 pkgconf`
   must succeed. If either fails, that is a blocker (fixing it needs
   `sudo` or the user): see "Final signal".
2. **Baseline** on the base commit, before touching code: `make build`
   (keep its warnings), `make test` (keep the test count and any failure:
   one that also fails here is pre-existing, not yours) and `make release`.
3. **Review** with **skillbox:code-reviewer** agents in parallel, each given
   the rules and constraints above: one for `CasperGit`, `Clibgit2` and
   `CSigbusGuard`; one for `CasperCore`; one for `CasperGhostty`; one for
   `CasperAgents`, `CasperCLI` and `Sources/casper` (with the CLI contract
   against `casper-skills`); `CasperUI` (the largest module) split by area
   after listing its files, for instance the diff view, the browser and info
   panel, and the sidebar, window chrome and app lifecycle; one for
   `Tests/` (dead or duplicated helpers, vacuous assertions); one for the
   build and release tooling (`Makefile`, `Package.swift`, `Scripts/`,
   `Packaging/`, `.github/workflows/`); one for cross-module duplication;
   one for the docs and the memory.
4. **Apply**: merge the findings into one list, then apply all of them, in
   small logical commits on this branch.
5. **Verify**: `make build` with no warning beyond the baseline, `make test`
   with at least the baseline's test count and no new failure,
   `make release`. Re-read the docs touched by a behaviour change against
   the code.
6. **Final pass**: a last **skillbox:code-reviewer** pass on the whole
   branch diff (`git diff {{BASE}}...HEAD`), then apply what it finds and
   verify again.

## Final signal

The report, in both modes: findings per rule and how each was fixed; doc
and memory corrections with their source; lines of code removed
(`git diff --shortstat {{BASE}}...HEAD`); test count before and after;
user-visible changes and their `CHANGELOG.md` entries; the manual checks to
run in `make dev`; questions left open (doc versus code, contract bugs);
recommendations not applied and why; commits.

**Foreground**: report to the user in the conversation.

**Delegated** (mandatory): when everything is applied, verified and
committed, write the completion file:

```bash
cat > {{DONE_FILE}} <<'END_OF_REPORT'
DONE
<the report>
END_OF_REPORT
```

The first line of the file is `DONE`; the heredoc ends at `END_OF_REPORT`,
so never use that word alone on a line of the report.

Then run `casper notify --message "The full code review is done"`.

If you hit a blocker you cannot resolve on your own (a decision only the
user can make, a broken tool or toolchain), still write that file, with
`BLOCKED` on its first line followed by the reason, run `casper notify` and
`casper status set blocked`, and ask your question in this session. Another
session waits on that file: never end without writing it.
