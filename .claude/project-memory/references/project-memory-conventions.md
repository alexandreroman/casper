---
name: "Project memory conventions"
description: "How to name project-memory files and what belongs in memory vs .superpowers/status.md"
type: feedback
---

# Project memory conventions

Two standing rules for maintaining `.claude/project-memory/`.

## File naming

Reference **filenames** are named by what they describe (e.g. `repo-config.md`,
`gui-synthetic-input.md`), **without** a `casper` prefix. The whole project is
Casper, so a `casper-` prefix is redundant noise. The `name:` field carries the
human-readable title, which must match the file's `# H1`. Match the existing
unprefixed naming when creating a note.

## Line width exemptions

Markdown here wraps at 80 characters, with three accepted exemptions.
`MEMORY.md` is exempt because the skill mandates one line per entry, each under
150 characters, so an entry cannot be wrapped. All YAML frontmatter is exempt:
`name:` and `description:` are single-line scalars and cannot wrap. And a line
whose overflow is a single unbreakable token — a code identifier, a path, a URL
— stays long rather than being broken mid-token; wrap the prose around it
instead.

## Memory vs status

Project memory holds durable, non-obvious knowledge that outlives any one
milestone: design decisions and their rationale, invariants, corrective
feedback, external references. It does **not** hold feature/implementation
status — what is shipped, what remains, "X is complete", progress checklists.
That lives in `.superpowers/status.md`, the single authoritative
implementation-progress record (per-feature sections with a ✅/◐/❌ legend).

**Why:** the two are different kinds of record with different lifetimes; mixing
status into memory duplicates `status.md` and rots as work progresses.

**How to apply:** when finishing a feature, update `.superpowers/status.md` with
the status and keep only the durable decisions/rationale in a memory note. If a
note starts saying "shipped" / "remaining" / "complete", move that to
`status.md`.
