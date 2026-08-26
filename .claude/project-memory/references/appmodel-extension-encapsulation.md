---
name: "AppModel encapsulation across extension files"
description: "spaces and diffScrollTarget keep private(set); extension files write them through named mutators"
type: project
---

# AppModel encapsulation across extension files

`AppModel` is split across `AppModel.swift` and four extension files:
`AppModel+Spaces.swift`, `AppModel+WorkspaceLifecycle.swift`,
`AppModel+Control.swift` and `AppModel+Presentation.swift` — the last one reads
model state as much as the others do, so it is bound by the same rule. Swift's
`private` is file-scoped, so a member the extensions touch has to be at least
internal — which costs the read-only-from-outside invariant on a stored
property.

Two properties keep that invariant because each has only a handful of write
sites, and both mutators live in `AppModel.swift` next to the property they
guard:

- `private(set) var spaces: [Space] { didSet { refreshMenuFlags() } }` — the
  extensions write it through `mutateSpaces(_:)`, which takes an
  `(inout [Space]) -> Void` body. An `inout` access fires `didSet` once, when
  the body returns, so `refreshMenuFlags()` behaves exactly as it does for a
  direct mutation. Reads through the subscript (`spaces[i].folderPath`) need no
  mutator — `private(set)` leaves the getter internal.
- `private(set) var diffScrollTarget` plus `private var diffScrollNonce` —
  both are written together by `requestDiffScroll(workspaceID:file:)`. The
  pairing is the point: the nonce bump is what makes a repeated request for the
  same file a distinct `DiffScrollTarget` value, so `DiffSurfaceView`
  re-scrolls instead of ignoring an unchanged target.

Members with many call sites across the extensions stay plainly internal; the
mutator pattern is worth it only where the write sites are few.
