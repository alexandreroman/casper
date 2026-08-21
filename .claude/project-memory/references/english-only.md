---
name: "English only"
description: "All generated text (docs, code, UI, commit messages) in the Casper project is written in English; commit subjects use a verb + action format"
type: feedback
---

# English only

Every piece of text generated for the Casper project is written in **English** —
documentation, code (identifiers, comments, log/error strings), and UI elements
(labels, menu titles, notification copy). No French lands in committed artifacts
or the shipped app.

Chat replies to the user may stay in the user's language; anything landing in
the repo or the app is English.

**Commit messages** follow the same rule (subject AND body in English) and use a
**verb + action performed** subject, e.g. "Simplify the diff parser", "Add the
port allocator". This applies on top of the [git workflow](git-workflow.md)
note: authorization before committing/pushing still stands.

**Why:** English throughout, and a consistent verb-first subject, are
project-wide conventions.

**How to apply:** use English for all docs, source, and user-facing strings, and
write commit subjects as an English verb followed by the action done. Keep
commit subjects concise.
