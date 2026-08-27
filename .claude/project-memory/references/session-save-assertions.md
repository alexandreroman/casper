---
name: "Asserting that a production path saved the session"
description: "flushPendingSave() persists unconditionally, so a test that calls it proves the codec, never that the code under test wrote anything"
type: feedback
---

# Asserting that a production path saved the session

`AppModel.flushPendingSave()` calls `persist()` itself before draining the save
queue. A test that drives some model call, then flushes, then reloads the store
therefore passes whether or not the call under test saved anything: the flush
supplies the write. Such a test pins the **codec** — that a field survives
`SessionStore`'s encode and comes back on a model built from the decoded session
— and its name should say so.

To pin that a *production path* reaches disk, let that path's own `persist()` be
the only write and poll the store until the backgrounded write lands:

```swift
let deadline = Date().addingTimeInterval(2)
while Date() < deadline {
    if let value = (try? store.load())?.someField { return value }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
```

`persist()` enqueues onto a serial queue, so a poll for the expected value never
sees a later write out of order, and a load racing a partial file simply throws
and is retried.

**The other half is the fixture.** Most writes reach disk through some
*neighbouring* save, so a test meant to pin one call's save has to be set up so
nothing else along the path writes. `selectWorkspace` encodes only when the
selection actually changes, but `reconfigureWorktreeWatcher` →
`promoteSpaceIfGitInitialized` writes whenever a Space's folder has *become* a
Git repository since it was adopted — which is exactly what creating a Space at
a tracked path does. Seeding the fixture with a Space that is already Git-backed
removes that second writer and leaves the call under test as the only one.

**How to apply:** before trusting a persistence test, break the save under test
and watch it fail. A green test that stays green is the signature of both traps.
