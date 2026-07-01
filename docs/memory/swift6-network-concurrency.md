---
name: swift6-network-concurrency
description: NWListener/NWConnection-based classes use @unchecked Sendable + queue discipline in CasperAgents
type: reference
---

# Swift 6 Network.framework concurrency

Under Swift 6 strict concurrency, classes that own `NWListener` /
`NWConnection` from Network.framework do not compile with plain `[weak self]`
handler closures: the framework's handlers are `@Sendable` and capture
non-Sendable `self`. Converting such a class to an `actor` is rejected because
it would force the public API to become `async`.

Established convention in the `CasperAgents` module (first used by
`HookSocketServer` in `Sources/CasperAgents/HookSocket.swift`, Plan 3 / Task 8):

- Mark the class `final class X: @unchecked Sendable` when it must keep a
  synchronous public interface (`start()` / `stop()` etc.).
- Justify the `@unchecked` inline: correctness relies on discipline the
  compiler cannot verify — set closure properties (e.g. `onMessage`,
  `onFailure`) before `start()`, and perform all I/O on the owned serial
  `DispatchQueue`.
- Avoid a *second* `@unchecked`: instead of a mutable local `var buffer`
  captured across nested receive callbacks, thread accumulated state by value
  through a helper method (e.g. `receiveChunk(on:accumulated:)`).

Do not reach for `@unchecked Sendable` elsewhere without this justification;
prefer restructuring first.
