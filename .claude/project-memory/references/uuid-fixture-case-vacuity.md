---
name: "UUID fixtures must carry hex letters"
description: "A digit-only UUID literal makes any case-sensitivity assertion silently vacuous; fixtures spell both cases out"
type: feedback
---

# UUID fixtures must carry hex letters

A test that pins the case of a UUID needs a fixture containing **hex letters**
(`a`–`f`). The canonical placeholder ids — `11111111-1111-…`,
`22222222-2222-…` — are digits only, so `"1111…".uppercased()` returns the
identical string and the assertion passes against a case-*sensitive*
implementation. The test looks like coverage and proves nothing.

Two rules for such fixtures:

- Use a letter-bearing id, e.g. `abcdef01-abcd-4bcd-8bcd-abcdef012345`.
- Spell both cases out as literals rather than deriving one from the other with
  `.uppercased()` / `.lowercased()`, so the expectation cannot drift with the
  code under test.

The same trap applies to `UUID()`: a randomly minted id can be all digits, so a
"contains no uppercase character" check on a random id is a probabilistic guard,
not a proof. Pair it with one deterministic, letter-bearing case.

**Why:** id case is a boundary contract in Casper (emitted lowercase, matched
case-insensitively — see `.superpowers/themes/cli-agents.md`), and a vacuous
test leaves that contract unguarded.

**How to apply:** verify a case-related test by mutating the implementation back
to the case-sensitive form and confirming the test actually fails.
