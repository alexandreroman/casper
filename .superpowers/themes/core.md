# Theme: Core (CasperCore)

**Module:** CasperCore · **Status:** ✅ built (see `../status.md`) · **Code:**
`Sources/CasperCore/`

The pure-Swift, UI-free core. Fully unit-tested.

## Design

- **Models** — the canonical data model (see `../architecture.md`): `Session`,
  `Space`, `Workspace` (with `WorkspaceKind`, `InspectorState`/`InspectorTab`
  and `EditorKind`), `LayoutNode`, `Surface`, `Todo`/`TodoStatus`, `AgentState`.
- **`LayoutTree`** — the pure engine behind the tmux-style pane layout:
  `split`, `closeSurface`, `move`, `dropZone`, `updateRatios`, `updateSurface`,
  `orientationAndSide`, `contains`, plus the read-only walks `forEachSurface`,
  `surfaceIDs` and `surfaces`. The detection tick runs on **`forEachSurface`**
  every pass, deliberately not on `surfaces(_:)`: the latter materializes a
  throwaway array of full `Surface` values — browser URLs and all — for every
  workspace, four times a second. Heavily tested, and the reason pane
  restructuring needs no UI state (see `app-ui.md` § Design → "Layout
  composition").
- **Agent state** — `Workspace.agentState` (an `AgentState` enum) and its
  `todos` have **two** producers. The control-channel handlers
  (`casper status set` / `progress set`) write the fields directly and are
  authoritative. The detection tick is the second: it feeds each surface's
  signals through `AgentStateResolver` — a per-workspace `struct` holding
  `observedWorking` / `idleStreak` / `doneLatched` behind a
  `mutating func resolve(...)`, so it is a small state machine — and lands the
  result through `setDetectedAgentState`, which never grants authority to a
  detected value. Only the resolver is in this module: the tick itself and
  `setDetectedAgentState` live on CasperUI's `AppModel`, since landing a result
  means mutating the observable model. See `agent-state-detection.md`.
- **`WorktreeManager`** — create/remove/deleteBranch/isClean/`merge` over
  `CasperGit`, plus `registeredName` (a worktree's admin entry resolved by path,
  since an adopted worktree can carry any name), `resyncWorkingTree`,
  `canonicalPath` and `claimWorktreePath`, mapping failures to `WorktreeError`
  (see `git-worktrees.md`). `claimWorktreePath` reclaims a path an IDE
  re-created after the worktree there was deleted: it deletes the directory
  only when it is a real directory, the repository answers that no worktree
  lives there, and every top-level entry is on an allow-list of editor metadata
  (`.idea`, `.vscode`, …) — every doubt answers false. See
  [[ide-recreates-worktree-directory]]. Its entry points are static and not
  actor-isolated, so the close/delete paths can offload them to a detached task.
- **`PortAllocator`** — assigns the first free contiguous **10-port block** from
  a configurable range. The default `40000–49990` bounds the block **base**, not
  the highest allocatable port: a block spans `base ... base + 9`, so the last
  block is 49990–49999 and there are ~1000 of them. The base is persisted as
  `portBase`, released on workspace removal. **Logical only** — blocks never
  overlap, but ports are not OS-bound. The scan starts at a **randomized** block
  base per app instance (`randomStartBase`) and wraps around, so two concurrent
  instances (e.g. a `--session` test build alongside the real one) statistically
  hand out different blocks to their first workspaces — a mitigation, not strict
  isolation.
- **`SessionStore`** — `Codable` + `FileManager` persistence; self-heals a
  layout file it cannot decode by moving it aside to a sibling `.corrupt` file,
  kept for diagnostics, and starting from an empty `Session`. It carries **no
  debounce of its own** — every call writes. The coalescing lives one layer up,
  in CasperUI's `AppModel`, whose `scheduleSave()` re-arms a 0.5 s `Debouncer`
  around `persist()`. Only the few high-frequency edits take that path (a
  committed browser URL, an inspector width or split ratio being dragged, a
  font-size change); the great majority of save sites call `persist()` directly,
  and `flushPendingSave()` cancels the pending timer and writes at once for
  quit-safety. The layout file is `session.json` by default, or
  `session-<name>.json` when the app is launched with `--session <name>` — a
  **DEBUG-only** flag, since `SessionIdentity.parse` ignores the argument
  outright in a release build (see [[app-sessions]]) — so a named session never
  clobbers the default instance's layout. The **six** transient runtime fields
  (`agentState`, `todos`, `pendingNotification`, `pendingNotificationMessage`,
  `infoMarkdown`, `infoUnread`) are intentionally **not** persisted:
  `Workspace`'s hand-rolled coders neither write nor read them, so they reset on
  load.
- **Control channel** — `ControlProtocol.swift` (the `ControlCommand` /
  `ControlResponse` wire types) + `ControlSocket.swift` (the release Unix-domain
  server/client, declared as the `ControlSocketServer` / `ControlSocketClient`
  typealiases over the engine; neither file declares a type of its own name)
  over the shared `SocketTransport` (symmetric 4-byte big-endian length-prefixed
  framing with an 8 MB per-frame guard, applied in both directions so a
  malformed peer cannot force an unbounded allocation; one
  `SocketTransportError` serves both channels; a refused connect — the stale
  socket file a crashed instance leaves — fails the client at once rather than
  at its timeout; a retriable verb retries only a failed connection, never an
  attempt that timed out waiting for the reply), plus the pure CLI helpers
  `ProgressSynthesis`, `ControlTargeting`, and `GitBranchName`. Concurrency
  discipline for the socket classes is in [[swift6-network-concurrency]].
- **`SessionIdentity`** — the name that suffixes a session's layout file and
  socket paths so a dev/test instance runs beside the user's real one. A `nil`
  name is the default session, whose paths stay byte-for-byte the historical
  ones. See [[app-sessions]] and [[socket-listen-vs-dial-path]].
- **`CasperEnvironment`** — the `CASPER_*` names shared between the side that
  writes them and the side that reads them, spelled once: the terminal
  environment (CasperAgents' `AgentEnvironment`) and the CLI, or the debug
  driver and `DebugSocketPath`. The names are a contract with the agent plugins
  and never change. A debug knob with a single reader (the hang watchdog's, the
  toolbar probe's) stays a literal next to that reader.
- **`RepoConfig`** — the per-repository `.casper.json` loader/validator, with
  `WorkspaceFileCopier` seeding its `copyFiles` patterns into a new worktree.
  The design decisions live in `cli-agents.md` § Design → "Per-repository
  config".
- **Agent detection** — `AgentDetection.swift` (the pure matcher/resolver, whose
  types are `AgentSignal`, `AgentProgressState`, `AgentDetectionRuleSet` and
  `AgentStateResolver` — there is no `AgentDetection` type) and
  `AgentIntegration`/`AgentIntegrationProbe` (is each agent's Casper plugin
  installed). Design in `agent-state-detection.md` and `cli-agents.md`.
- **Filesystem & timing utilities**, all deliberately model-free:
  - **`DirectoryWatcher`** — a native FSEvents wrapper over a path subtree with
    exclusions, delivering coalesced changes on a private serial queue; hopping
    to the main actor is the caller's job. It knows nothing of `Workspace`,
    `Repository` or SwiftUI. Gotchas in [[fsevents-directory-watcher]].
  - **`Debouncer`** — a main-actor coalescing timer: each `schedule` cancels the
    pending work and re-arms, so a burst fires once. It is what CasperUI's
    `AppModel` drives its session-save and diff-refresh debounces with, and
    CasperGhostty's `GhosttySurfaceView` its 0.25 s surface-creation retry.
  - **`MainRunLoop`** — the modal-proof main-thread hop: `perform` enqueues a
    block on the main run loop, modal and tracking modes included, so it runs
    while an alert, panel or menu is up, where the main dispatch queue starves.
    CasperUI's watcher refreshes and lifecycle resumes and the hang watchdog's
    liveness ack all ride it; see [[main-run-loop-hop]].
  - **`LoginShellPath`** — probes the user's shell for its `PATH` once per
    process, then resolves command names against it in Swift; the design is in
    `cli-agents.md` and [[shell-path-resolution]].
  - **`SpaceName`** / **`IdentifierFormatting`** — display-name derivation for a
    Space, and `UUID.casperID`, the lowercase canonical external form every id
    Casper emits uses.
- **Debug channel wire** — **DEBUG-only**: `DebugProtocol.swift` (the
  `DebugCommand` / `DebugResponse` wire types) and `DebugSocket.swift`
  (`DebugSocketPath` and the server/client typealiases over the same
  `SocketTransport`). See `debug.md` and [[debug-channel-gating]].
- **`CasperLog`** — the `os.Logger` facade: one subsystem, the `debug-casper`
  skill's filter key, split into categories. `.notice`/`.error`/`.fault` calls
  ship in release; verbose `.debug`/`.info` call sites are wrapped in
  `#if DEBUG`.
- **`LiveObjectCensus`** / **`ProcessMemory`** — **DEBUG-only**, the weak-ref
  live-object census and the process footprint behind `casper debug memory`
  (see `debug.md` and [[memory-observability]]).
- **`MainThreadHangWatchdog`** — **DEBUG-only** freeze diagnosis: it detects a
  blocked main thread and, on the first stall of an episode, spawns
  `/usr/bin/sample`. The whole file compiles out of release. See
  [[hang-dump-watchdog]].
