---
name: "An empty array casts to any array type"
description: "A dynamic array cast checks elements one at a time, so an empty array satisfies every array type; a Mirror-based absence assertion is vacuous whenever the fixture leaves such a property empty"
type: feedback
---

# An empty array casts to any array type

A dynamic array cast in Swift checks the elements **one at a time**, so an array
with no elements satisfies every array type there is:

```swift
let empty: Any = [Int]()
empty is [String]                 // true
empty is Array<Array<UUID>>       // true
let filled: Any = [1]
filled is [String]                // false
```

The cast is not a type-identity test. Two array types share only `Array`'s
shape, and with no element to check the bridge has no reason to say no.

**Why:** this turns a "does this type store a `T`?" test into a false positive
the moment its fixture leaves a same-shaped property empty. Reflecting over
`SplitContainerView` for a stored property holding an array of arrays of `UUID`
finds `path`, which is `[Int]`, and a fixture that passes an empty `path` makes
the mirror report a cached pane-identity array the view does not have. The suite
then fails on a property that is doing nothing wrong, and the real subject is
never reached.

**How to apply:** do not reflect over stored properties to assert a type's
**absence**. `Mirror` reports what a value happens to hold, not what its type is
declared to hold, and a negative read off it is only as strong as the fixture
that filled it — the same vacuity trap as [[uuid-fixture-case-vacuity]], one
level further in. Assert the behaviour the absence is supposed to guarantee
instead (that the view re-reads its identities, that a stale one cannot survive
a change), and let that fail for a reason a reader can act on. Where a dynamic
array cast is genuinely wanted, guard it with `!array.isEmpty` so the empty case
is decided deliberately rather than by the bridge's element-wise rule.
