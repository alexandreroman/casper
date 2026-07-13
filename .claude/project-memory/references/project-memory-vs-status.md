---
name: "Feature status belongs in .superpowers/status.md, not project memory"
description: "Implementation status (shipped/remaining/progress) goes in .superpowers/status.md; project memory holds durable decisions only"
type: feedback
---

# Feature status belongs in .superpowers/status.md, not project memory

Do NOT record feature/implementation status — what is shipped, what remains, "X
is complete", progress checklists — in project memory. That lives in
`.superpowers/status.md`, the single authoritative implementation-progress record
(per-feature sections with a ✅/◐/❌ legend).

Project memory (`.claude/project-memory/`) is for durable, non-obvious knowledge
that outlives any one milestone: design decisions and their rationale,
invariants, corrective feedback, external references. Status is transient and has
its own home.

**Why:** the two are different kinds of record with different lifetimes; mixing
status into memory duplicates `status.md` and rots as work progresses.

**How to apply:** when finishing a feature, update `.superpowers/status.md` with
the status; put only the durable decisions/rationale in a project-memory note. If
a memory note starts saying "shipped" / "remaining" / "complete", move that to
`status.md`.
