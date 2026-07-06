# Theme: Core (CasperCore)

**Module:** CasperCore · **Status:** ✅ built (see `../status.md`) ·
**Code:** `Sources/CasperCore/`

The pure-Swift, UI-free core. Fully unit-tested.

## Design

- **Models** — the canonical data model (see `../architecture.md`): `Session`,
  `Space`, `Workspace`, `LayoutNode`, `Surface`, `Todo`, `AgentState`.
- **Agent state** — `Workspace.agentState` (an `AgentState` enum) and its `todos`
  are plain fields set directly by the control-channel handlers
  (`casper status set` / `progress set`); there is no reducer or state machine.
- **`WorktreeManager`** — create/list/remove/deleteBranch/isClean over
  `CasperGit`, mapping failures to `WorktreeError` (see `git-worktrees.md`).
- **`PortAllocator`** — assigns the first free contiguous **10-port block** from a
  configurable range (default `40000–49990` → ~1000 workspaces), persisted as
  `portBase`, released on workspace removal. **Logical only** — blocks never
  overlap, but ports are not OS-bound.
- **`SessionStore`** — `Codable` + `FileManager` persistence, debounced on each
  mutation; self-heals a corrupt `session.json`. The transient agent state
  (`agentState`, `todos`, `pendingNotification`) is intentionally **not**
  persisted — it resets on load.
- **Control channel** — `ControlProtocol` (`ControlCommand`/`ControlResponse`
  wire types) + `ControlSocket` (the release Unix-domain server/client), plus the
  pure CLI helpers `ProgressSynthesis`, `ControlTargeting`, and `GitBranchName`.

## Remaining

None for the core itself.
