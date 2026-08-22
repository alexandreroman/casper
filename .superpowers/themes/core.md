# Theme: Core (CasperCore)

**Module:** CasperCore · **Status:** ✅ built (see `../status.md`) · **Code:**
`Sources/CasperCore/`

The pure-Swift, UI-free core. Fully unit-tested.

## Design

- **Models** — the canonical data model (see `../architecture.md`): `Session`,
  `Space`, `Workspace`, `LayoutNode`, `Surface`, `Todo`, `AgentState`.
- **Agent state** — `Workspace.agentState` (an `AgentState` enum) and its
  `todos` are plain fields set directly by the control-channel handlers
  (`casper status set` / `progress set`); there is no reducer or state machine.
- **`WorktreeManager`** — create/list/remove/deleteBranch/isClean over
  `CasperGit`, mapping failures to `WorktreeError` (see `git-worktrees.md`).
- **`PortAllocator`** — assigns the first free contiguous **10-port block** from
  a configurable range (default `40000–49990` → ~1000 workspaces), persisted as
  `portBase`, released on workspace removal. **Logical only** — blocks never
  overlap, but ports are not OS-bound. The scan starts at a **randomized** block
  base per app instance (`randomStartBase`) and wraps around, so two concurrent
  instances (e.g. a `--session` test build alongside the real one) statistically
  hand out different blocks to their first workspaces — a mitigation, not strict
  isolation.
- **`SessionStore`** — `Codable` + `FileManager` persistence, debounced on each
  mutation; self-heals a corrupt layout file. The layout file is `session.json`
  by default, or `session-<name>.json` when the app is launched with
  `--session <name>` (see [[app-sessions]]), so a named session never clobbers
  the default instance's layout. The transient agent state (`agentState`,
  `todos`, `pendingNotification`) is intentionally **not** persisted — it resets
  on load.
- **Control channel** — `ControlProtocol` (`ControlCommand`/`ControlResponse`
  wire types) + `ControlSocket` (the release Unix-domain server/client) over the
  shared `SocketTransport` (symmetric 4-byte big-endian length-prefixed framing
  with an 8 MB per-frame guard, applied in both directions so a malformed peer
  cannot force an unbounded allocation), plus the pure CLI helpers
  `ProgressSynthesis`, `ControlTargeting`, and `GitBranchName`. Concurrency
  discipline for the socket classes is in [[swift6-network-concurrency]].
- **`SessionIdentity`** — the name that suffixes a session's layout file and
  socket paths so a dev/test instance runs beside the user's real one. A `nil`
  name is the default session, whose paths stay byte-for-byte the historical
  ones. See [[app-sessions]] and [[socket-listen-vs-dial-path]].
- **`RepoConfig`** — the per-repository `.casper.json` loader/validator, with
  `WorkspaceFileCopier` seeding its `copyFiles` patterns into a new worktree.
  The design decisions live in `cli-agents.md` § Design → "Per-repository
  config".
- **Agent detection** — `AgentDetection` (the pure matcher/resolver) and
  `AgentIntegration`/`AgentIntegrationProbe` (is each agent's Casper plugin
  installed). Design in `agent-state-detection.md` and `cli-agents.md`.
- **Filesystem & timing utilities**, all deliberately model-free:
  - **`DirectoryWatcher`** — a native FSEvents wrapper over a path subtree with
    exclusions, delivering coalesced changes on a private serial queue; hopping
    to the main actor is the caller's job. It knows nothing of `Workspace`,
    `Repository` or SwiftUI. Gotchas in [[fsevents-directory-watcher]].
  - **`Debouncer`** — a main-actor coalescing timer: each `schedule` cancels the
    pending work and re-arms, so a burst fires once. The `SessionStore` save
    idiom, extracted.
  - **`LoginShellPath`** — resolves a command against the user's **login shell**
    `PATH`, which Casper's own environment lacks because it is launched from
    Finder/Dock.
  - **`SpaceName`** / **`IdentifierFormatting`** — display-name derivation for a
    Space, and `UUID.casperID`, the lowercase canonical external form every id
    Casper emits uses.
- **`MainThreadHangWatchdog`** — **DEBUG-only** freeze diagnosis: it detects a
  blocked main thread and, on the first stall of an episode, spawns
  `/usr/bin/sample`. The whole file compiles out of release. It stays wired
  until the diff-view hang is confirmed fixed live — see [[hang-dump-watchdog]]
  and [[diff-view-refresh-hang]].

## Remaining

None for the core itself.
