# Theme: Core (CasperCore)

**Module:** CasperCore · **Status:** ✅ built (see `../status.md`) ·
**Code:** `Sources/CasperCore/`

The pure-Swift, UI-free core. Fully unit-tested.

## Design

- **Models** — the canonical data model (see `../architecture.md`): `Session`,
  `Space`, `Workspace`, `LayoutNode`, `Surface`, `Todo`, `AgentState`.
- **`AgentStateStore`** — the per-workspace state machine + todo list. The pure
  `AgentStateReducer` maps the four incoming hook events only —
  `SessionStart` → running/idle, `Notification` → waiting, `Stop` → done,
  `PostToolUse:TodoWrite` → progress (`completed/total`, current `in_progress`).
  It deliberately does **not** produce `unknown`/`error`: those come from the
  socket/heartbeat layer (see `cli-agents.md`), because the reducer cannot detect
  "no hooks arrived" or a broken pipe.
- **`WorktreeManager`** — create/list/remove/isClean over `CasperGit`, mapping
  failures to `WorktreeError` (see `git-worktrees.md`).
- **`PortAllocator`** — assigns the first free contiguous **10-port block** from a
  configurable range (default `40000–49990` → ~1000 workspaces), persisted as
  `portBase`, released on workspace removal. **Logical only** — blocks never
  overlap, but ports are not OS-bound.
- **`SessionStore`** — `Codable` + `FileManager` persistence, debounced on each
  mutation; self-heals a corrupt `session.json`.
- **Hook-event parser** — decodes the Claude Code hook JSON into typed events.

## Remaining

None for the core itself. The `onMessage` → `AgentStateStore` wiring and the
heartbeat *timer* are consumed by CasperUI/CLI — tracked under `cli-agents.md`.
