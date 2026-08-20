# Theme: CLI & Agent Environment (CasperCLI + CasperAgents)

**Modules:** CasperCLI + CasperAgents · **Status:** ✅ built (see `../status.md`)
· **Code:** `Sources/CasperCLI/`, `Sources/CasperAgents/`

The single GUI+CLI binary, its domain command surface, and the per-surface
environment that lets an agent in a terminal report its state through the CLI.

## Design

### Single binary (GUI + CLI)

The bundle executable inspects its argv: empty → **GUI mode**; a recognized
subcommand (e.g. `casper status …`, `casper terminal new`) → **CLI mode**,
which runs and exits. Parsing uses swift-argument-parser; the fork happens
before the `ParsableCommand` tree.

### Domain CLI (`casper <domain> <verb>`)

The CLI is organized by domain, one noun per area of app state, each with a
handful of verbs:

- `status set <state>` — set the agent state of a workspace.
- `progress set --total --current --label` / `progress clear` — set or clear
  todo progress.
- `notify [--message <str>]` — raise the attention flag; `--message` also
  posts a macOS notification (suppressed when the target is already focused).
- `info set [--message <str> | --file <path> | -]` — replace the workspace's
  info-panel Markdown message, read from the flag, a file, or stdin. `-`
  reads stdin explicitly; a bare invocation reads stdin too, but only when it
  is not a TTY (piped or redirected) — at an interactive terminal it errors
  instead of hanging. `info clear` — empty the panel and hide its button. The
  panel keeps only the latest message and never persists it across restarts.
- `terminal new [--command <cmd>] [--working-dir <dir>]` — open a terminal,
  split below (cwd defaults to the worktree); `terminal list` — list the
  workspace's terminals; `terminal close <id>` — close a terminal by id.
  `--command` types the given text into the newly opened terminal's real login
  shell once it starts, via `ghostty_surface_text` right after the surface is
  created. Both of libghostty's own config fields are deliberately left unused:
  `command` (the vendored fork execs it as `bash -l -c "exec …"`, ignoring the
  user's real shell) and `initial_input` (it mojibakes non-ASCII — see
  [[ghostty-initial-input-utf8]]). The text therefore inherits the user's actual
  `$SHELL` and PATH (Homebrew, mise, etc., from `~/.zprofile`/`~/.zshrc` for a
  zsh user). It is typed as plain text, not `exec`'d: after the command exits,
  the terminal returns to an interactive shell prompt rather than closing, and a
  compound command (`a ; b ; c`) runs in full. A launch command is a one-shot
  instruction, not persisted — restoring a saved session never re-runs it.
- `browser open <url>` — load an **absolute** URL (scheme + host) into the
  workspace's single **inspector** browser surface and select the browser tab.
  Browser surfaces can also be layout panes (`Surface.Kind.browser`, the "New
  browser" split), but this verb specifically targets the inspector browser, not
  a layout pane. `browser load <url>` is the same navigation **without** opening
  or selecting the inspector (a background load). `browser close` — collapse the
  inspector if the browser tab is the one showing.
- **Browser automation and debugging** — the same inspector browser doubles as a
  drivable surface, so an agent can verify the frontend change it just made.
  Every verb targets a workspace by id independently of selection and works
  off-screen:
  - `browser screenshot [--out <path>] [--width <n>] [--height <n>]
    [--url <url>]` — write a PNG (a temp file when `--out` is omitted); a sized
    or `--url` capture renders in a dedicated off-screen `WKWebView`.
  - `browser content [--selector <css>] [--raw]` / `browser url [--raw]` —
    print the page's HTML, or its current URL.
  - `browser eval <js> [--raw]` — evaluate JavaScript and print the result.
  - `browser click <selector>` / `browser type <selector> <text>` /
    `browser key <key> [--selector <css>]` — JS-synthesized input against the
    first matching element (`key` defaults to the focused one).
  - `browser console [--level <lvl>] [--clear]` — print the captured `console.*`
    output and uncaught errors (a 500-entry ring buffer fed by an injected
    `WKUserScript`).
  - `browser wait <selector> | --js <expr> [--visible|--gone] [--timeout <ms>]`
    — block until a selector is present/visible/gone or a JS predicate holds.
  - `browser reload [--wait]` — reload the page.
  - `browser scroll-up` / `scroll-down` / `scroll-top` / `scroll-bottom` —
    scroll by one viewport, or jump to either end.

  See [[browser-automation-cli]] for the synthesized-input, snapshot and
  off-screen caveats.
- `diff open [<file>]` — open the diff view and scroll to `<file>` (which must
  exist on disk and be inside the worktree, else an error). `diff close` —
  collapse the inspector if the diff tab is the one showing.
- `workspace list` / `workspace current` /
  `workspace new <branch> [--base <ref>] [--command <cmd>]` /
  `workspace delete` — enumerate, identify, create, and destroy workspaces. The
  branch name is a **positional argument**, not a flag; `--base` forks from a
  ref other than the space's base branch, and `--command` seeds the workspace's
  first terminal. `workspace delete` is **destructive** (prunes the worktree
  folder,
  deletes the branch, drops it from the UI) and **refuses a primary workspace**.
- `run [<name>]` — run a named command from the workspace's `.casper.json` in
  a new visible terminal (defaults to the command named `run`). Not scoped
  under its own noun like the others, but still a workspace-targeted verb.

Every workspace-scoped command shares a `--workspace <id-or-name>` option,
defaulting to `$CASPER_WORKSPACE_ID` (set in every Casper terminal); this is
why plain `casper status set working` works with no flags inside a Casper
terminal but needs `--workspace` from anywhere else. The one deliberate
exception is `workspace current`: it answers "which workspace is *this*
terminal", so it reads `$CASPER_WORKSPACE_ID` only and takes no target option —
outside a Casper terminal it errors rather than defaulting to something.

Each command sends a `ControlCommand` to the running app over a Unix domain
socket named by `$CASPER_CONTROL_SOCKET` (also per-surface env, alongside
`$CASPER_WORKSPACE_ID` and `$CASPER_PORT`); the app replies with a
`ControlResponse`. If `$CASPER_CONTROL_SOCKET` is unset, the CLI exits with a
"Casper is not running" error instead of hanging. `casper debug …` is a
separate, `#if DEBUG`-only channel — never present in a release build. See
[[debug-channel-gating]].

### JSON output

Every command is machine-readable. On **success** it prints a JSON object (or
array) to stdout and exits 0, describing the resulting resource state and always
including the affected `workspace` id — e.g. `status set blocked` →
`{"status":"blocked","workspace":"<id>"}`; verbs with no meaningful state
(`progress clear`, `notify`, `browser open`, `diff open`) → `{"workspace":"<id>"}`.
`terminal new` carries `working-dir` (always) and `command` (when given);
`terminal list` carries only `working-dir` (it no longer carries `command` — a
terminal's launch command is a one-shot instruction, not durable state);
`workspace new`/`list`/`current` carry the worktree `path`
(`branch` omitted for a degenerate, non-Git space). On **error** it prints
`{"error":"<msg>"}` to stderr and exits **non-zero** — a command in error never
returns 0; validate CLI-side in `makeCommand()` where possible. ArgumentParser's
own output (`--help`, missing option, unknown flag) stays native.

### Agent state & progress

Casper has **no agent-hook mechanism** — no hook installation, no hook socket,
no `hooks` CLI. A workspace's agent state (`agentState`, todo progress, the
attention flag) is set **only** by the explicit domain verbs above: an agent (or
any tool) running in a Casper terminal calls `casper status set …`,
`casper progress set …`, and `casper notify …` itself. Casper **never launches an
agent**; the user runs their agent manually.

The only agent-facing runtime coupling is the per-surface environment
`ClaudeCodeAdapter.surfaceEnvironment` injects into every Casper terminal:
`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, `CASPER_PORT` in `linked`
workspaces only (a `primary` workspace gets none, so its dev servers keep the
project's default ports), and — when a debug build runs under `--session <name>`
(a `#if DEBUG`-only flag) — `CASPER_SESSION`. A CLI command reads
`CASPER_WORKSPACE_ID` for its default target and `CASPER_CONTROL_SOCKET` to
reach the app; state changes flow straight into the sidebar (badge, progress,
notification dot) and, for `notify`, `UserNotifications`.

When a debug build is launched with `--session <name>`, its control socket is
the session-scoped `casper-control-<name>.sock` and that path is the value
injected as `CASPER_CONTROL_SOCKET`, so the domain CLI keeps working unchanged
inside a named session's terminals (it never reads `CASPER_SESSION` — the
injected socket path already points at the right instance). See
[[app-sessions]].

The control socket class uses `@unchecked Sendable` + serial-queue discipline
under Swift 6 — see [[swift6-network-concurrency]].
