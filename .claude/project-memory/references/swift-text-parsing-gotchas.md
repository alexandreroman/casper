---
name: "Swift text-parsing gotchas"
description: "CRLF is one Character so split(separator: \"\\n\") fails; Swift Regex has no lookbehind"
type: reference
---

# Swift text-parsing gotchas

Two Swift-specific traps that hit every hand-written line parser in this
codebase (`AgentIntegration`'s TOML/JS scanners are the reference example).

**`"\r\n"` is a single `Character`.** Swift's `Character` is an extended
grapheme cluster, and CRLF forms one. `text.split(separator: "\n")` therefore
does **not** split a CRLF file at all — it returns the whole file as one line,
and every downstream check (section headers, `hasPrefix("//")` comment skips)
silently sees nothing. Splitting with `split(whereSeparator: \.isNewline)`
handles LF, CRLF and a lone CR alike. Trim with `.whitespacesAndNewlines` rather
than `.whitespaces` for the same family of reasons: `.whitespaces` excludes
`\r`.

**Swift Regex literals reject lookbehind.** `(?<=…)` and `(?<!…)` fail to
compile with "cannot parse regular expression: lookbehind is not currently
supported". To anchor the *leading* edge of an identifier, match an alternation
of the string start and a non-identifier character —
`/(?:^|[^A-Za-z0-9_])NAME\b/` — which needs no lookbehind and captures the same
positions. Lookahead is supported; only lookbehind is not.

**Why:** both traps fail in the silent direction. A CRLF config parses to
"nothing matched" rather than to an error, and a `\b`-only identifier match
happily reads a *prefixed* namesake's value (`PREV_NAME` matches `NAME\b`),
producing a confidently wrong answer from a file that looks fine.

**How to check:** a parser fed hand-written config or source needs a CRLF test
case and a prefixed/suffixed-namesake test case; neither is exercised by
fixtures written as Swift multi-line string literals, which are always LF.
