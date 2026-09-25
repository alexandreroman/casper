---
name: "GitHub release descriptions are unwrapped"
description: "Release descriptions carry no column limit; the 80-column sources are unwrapped when published"
type: feedback
---

# GitHub release descriptions are unwrapped

A GitHub release description has no column limit: each paragraph and each list
item sits on a single line. `CHANGELOG.md` and `Packaging/release-notes.md`
follow the repo's 80-column Markdown convention, and `Scripts/release-notes.sh`
joins their soft-wrapped lines when it builds the description.

**Why:** GitHub renders every newline in a release description as a line
break, so 80-column text shows up chopped mid-sentence on the release page.

**How to apply:** publish release text through `Scripts/release-notes.sh`
(the release workflow does), including a manual `gh release edit
--notes-file`. Any text written straight into a GitHub release is unwrapped
by hand. The source files stay wrapped at 80 columns.
