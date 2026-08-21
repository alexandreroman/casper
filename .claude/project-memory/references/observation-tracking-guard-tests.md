---
name: "Testing a guarded no-write with withObservationTracking"
description: "withObservationTracking proves a guarded mutation does NOT write to an @Observable property, with no instrumentation added to production code"
type: feedback
---

# Testing a guarded no-write with withObservationTracking

`withObservationTracking` can prove a guarded mutation does **not** write, with
no instrumentation added to production code, whenever the model under test is
`@Observable`. Register interest in the specific stored property the guard is
supposed to skip writing, drive the guarded call, and assert the `onChange`
callback never fires — Observation only tracks direct property access, so the
tracked expression must read that property itself, not a derived or computed
value.

**How to apply:**
`ControlHandlerTests.testMarkInfoSeenSkipsTheWriteWhenAlreadyRead` uses this to
pin `AppModel.markInfoSeen`'s already-read guard: the first call writes `spaces`
(through `updateWorkspace`'s subscript mutation, which fires `spaces`'s own
willSet/didSet), the test then wraps `withObservationTracking` around a read of
`model.spaces` and asserts its `onChange` closure never runs on the second call.
`onChange` is `@Sendable` even though the test only ever touches the model on
the main actor it also runs on, so the captured flag needs `nonisolated(unsafe)`
— the same rationale as [[isolated-deinit-ci-sigabrt]] for accepting it: the
test guarantees single-threaded access even though the compiler cannot see that.

This sits alongside [[headless-swiftui-layout-tests]] as another no-screen,
no-run-loop technique: proving a *negative* (a write that must not happen)
without adding any test-only hook to the model itself.

Related: [[isolated-deinit-ci-sigabrt]], [[headless-swiftui-layout-tests]].
