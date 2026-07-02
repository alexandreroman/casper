---
name: "Implementation workflow"
description: "Execute plans subagent-driven: one code-writer per task, review, commit per task"
type: feedback
---

# Implementation workflow

Execute implementation plans with **subagent-driven development**: dispatch one
`skillbox:code-writer` subagent per task, run a `skillbox:code-reviewer` review
between tasks, and **commit after each task** (multiple commits per plan, one per
task, rather than a single squashed commit at the end). Close with a final
whole-branch review before finishing.

**Why:** fresh per-task context keeps each subagent focused and its edits
reliable; the review-between-tasks loop catches spec/quality issues early; and a
commit per task yields a clean, bisectable history where each commit is an
independently reviewable, testable unit. It also composes with the project rule
that all code changes go through the `code-writer` agent (see the project
CLAUDE.md) and the [git workflow](git-workflow.md) note.

**How to apply:** drive execution with the `superpowers:subagent-driven-development`
skill; per task — dispatch `skillbox:code-writer` (TDD), generate a diff, dispatch
`skillbox:code-reviewer`, fix Critical/Important findings, then commit. Track
progress in the `.superpowers/sdd/progress.md` ledger. Commit authorization still
follows [git workflow](git-workflow.md) (explicit user go-ahead required).
