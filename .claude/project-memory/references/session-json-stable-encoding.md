---
name: "session.json byte-stable encoding"
description: "SessionStore encodes with .sortedKeys, so set-valued Session state persists as a sorted array"
type: project
---

# session.json byte-stable encoding

`SessionStore` builds its `JSONEncoder` with
`outputFormatting = [.sortedKeys]`, so `session.json` is byte-stable: the same
logical session serializes to the same bytes on every save. That keeps the file
readable, diffable, and comparable when inspecting a `session.json.corrupt`
backup.

A `Set` breaks that guarantee. Its iteration order depends on a per-process hash
seed, so a `Set` property encodes as a JSON array in a different order after
each launch even when nothing changed. Any set-valued state on `Session`
therefore encodes through a hand-rolled `encode(to:)` that writes
`theSet.sorted()`, while the in-memory property stays a `Set`
(`Session.dismissedAgentReminders` is the reference example). Decoding reads the
array straight back into the `Set`.

Hand-rolling `encode(to:)` forces the full `CodingKeys` case set and requires
each remaining property to be encoded explicitly; keep the case names identical
to the property names so the on-disk keys stay unchanged, and keep `Optional`
properties on `encodeIfPresent`/`decodeIfPresent` so an absent key still means
"not set" rather than a decode failure.
