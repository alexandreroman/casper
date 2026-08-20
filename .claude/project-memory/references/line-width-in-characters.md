---
name: "Line width is measured in characters"
description: "The 80/120-column limits count characters, not UTF-8 bytes — em dashes fool byte-counting tools"
type: feedback
---

# Line width is measured in characters

The project's line limits — Markdown 80 columns, code 120 — count **characters**
(display columns), not bytes.

Casper's prose uses em dashes (`—`) and arrows (`→`) heavily, and each takes 3
bytes in UTF-8. A byte-counting check therefore flags compliant 80-character
lines as 81–83 columns wide, which produces false "line too long" findings in
review, especially against `.superpowers/*.md`.

**How to measure:**

```bash
python3 -c "
import sys
for i, line in enumerate(open('FILE').read().splitlines(), 1):
    if len(line) > 80: print(i, len(line))
"
```

Avoid `awk 'length > 80'` and `wc -c`: in a UTF-8 locale on macOS both count
bytes for this purpose. There is no Markdown linter in the repo, so nothing
enforces the limit automatically; some pre-existing lines (tables, long URLs)
legitimately exceed it.
