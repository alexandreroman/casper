---
name: "Swift 6 Network concurrency"
description: "NWListener/NWConnection-based classes use @unchecked Sendable + queue discipline in CasperAgents"
type: reference
---

# Swift 6 Network concurrency

Under Swift 6 strict concurrency, classes that own `NWListener` / `NWConnection`
from Network.framework do not compile with plain `[weak self]` handler closures:
the framework's handlers are `@Sendable` and capture non-Sendable `self`.
Converting such a class to an `actor` is rejected because it would force the
public API to become `async`.

Established convention for the shared socket engine in
`Sources/CasperCore/SocketTransport.swift`, which both the release control
channel (`ControlSocketServer`) and the DEBUG `DebugSocketServer` are
typealiases of:

- Mark the class `final class X: @unchecked Sendable` when it must keep a
  synchronous public interface (`start()` / `stop()` etc.).
- Justify the `@unchecked` inline: correctness relies on discipline the compiler
  cannot verify — set closure properties (e.g. `onCommand`, `onFailure`) before
  `start()`, and perform all I/O on the owned serial `DispatchQueue`.
- Do not capture a mutable local `var buffer` across nested receive callbacks.
  Accumulate into a small queue-confined reference box instead (`ReadBuffer`,
  passed into `readExactly(_:on:into:completion:)`): `Network.framework`
  delivers a connection's callbacks serially on the queue it was started on, so
  the box is never shared across reads, and that confinement is what justifies
  its own `@unchecked Sendable`.
- Cross-thread mutable state (e.g. a set of in-flight connections touched by
  both `stop()` on the caller's thread and receive loops on the queue) is
  guarded by an `OSAllocatedUnfairLock`. When the guarded state is itself
  **non-`Sendable`** (e.g. it holds a `DispatchWorkItem`), construct the lock
  with `OSAllocatedUnfairLock(uncheckedState:)` and access it via
  `withLockUnchecked` — this is the lock's designed API for non-Sendable state
  and is *not* a second class-level `@unchecked`; the lock still supplies the
  mutual exclusion. (`ControlSocketServer.State`.)
- "No callback after `stop()`" invariant: mark the class state `stopped` under
  the lock, snapshot-and-cancel in `stop()`, then `queue.sync {}` as a barrier
  so any in-flight completion finishes before `stop()` returns. Consequence:
  `stop()` must never be called from within a callback that runs on the queue
  (it would deadlock on the barrier) — document that on the type.

Do not reach for `@unchecked Sendable` elsewhere without this justification;
prefer restructuring first.
