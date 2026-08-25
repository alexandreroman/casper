# Theme: CLI & Agent Environment (CasperCLI + CasperAgents)

**Modules:** CasperCLI + CasperAgents · **Status:** ✅ built (see `../status.md`)
· **Code:** `Sources/CasperCLI/`, `Sources/CasperAgents/`,
`Sources/CasperCore/AgentIntegration{,Probe}.swift`

The single GUI+CLI binary, its domain command surface, and the per-surface
environment that lets an agent in a terminal report its state through the CLI.

## Design

### Single binary (GUI + CLI)

The bundle executable inspects its argv **by shape, not by vocabulary**
(`LaunchMode.detect`). Empty argv → **GUI mode**. A first argument that does not
start with `-` → **CLI mode**, whatever the word is: `casper bogus` enters the
CLI and fails there with ArgumentParser's own "unknown subcommand" error, which
is the intent — a typo should be reported, not silently launch a window. A first
argument that *does* start with `-` is treated as an AppKit/system launch flag
(`-NSDocumentRevisionsDebugMode`, `-psn_0_12345`, `-AppleLanguages`) and means
GUI, with `-h`/`--help`/`--version` carved out as the exceptions that mean CLI.
Parsing uses swift-argument-parser; the fork happens before the
`ParsableCommand` tree is ever built.

### Domain CLI (`casper <domain> <verb>`)

The CLI is organized by domain, one noun per area of app state, each with a
handful of verbs:

- `status set <state>` — set the agent state of a workspace.
- `progress set --total --current --label` / `progress clear` — set or clear
  todo progress.
- `notify [--message <str>]` — raise the attention flag; `--message` also posts
  a macOS notification (suppressed when the target is already focused).
- `info set [--message <str> | --file <path> | -]` — replace the workspace's
  info-panel Markdown message, read from the flag, a file, or stdin. `-` reads
  stdin explicitly; a bare invocation reads stdin too, but only when it is not a
  TTY (piped or redirected) — at an interactive terminal it errors instead of
  hanging. `info clear` — empty the panel and hide its button. The panel keeps
  only the latest message and never persists it across restarts.
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
  There is no other browser to target: `Surface.Kind.browser` is reached only
  through `Workspace.inspector.browser`, splits always create a terminal, and a
  `.browser` layout leaf cannot be created at all (see `app-ui.md` § Design →
  "Inspector panel"). `browser load <url>` is the same navigation **without**
  opening or selecting the inspector (a background load). `browser close` —
  collapse the inspector if the browser tab is the one showing.
- **Browser automation and debugging** — the same inspector browser doubles as a
  drivable surface, so an agent can verify the frontend change it just made.
  Every verb targets a workspace by id independently of selection and works
  off-screen:
  - `browser screenshot [--out <path>] [--width <n>] [--height <n>] [--url
    <url>]` — write a PNG (a temp file when `--out` is omitted); a sized or
    `--url` capture renders in a dedicated off-screen `WKWebView`.
  - `browser content [--selector <css>] [--raw]` / `browser url [--raw]` — print
    the page's HTML, or its current URL.
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
  `workspace new <branch> [--base <ref>] [--command <cmd>]` / `workspace delete`
  — enumerate, identify, create, and destroy workspaces. The branch name is a
  **positional argument**, not a flag; `--base` forks from a ref other than the
  space's base branch, and `--command` seeds the workspace's first terminal.
  `workspace delete` is **destructive** (prunes the worktree folder, deletes the
  branch, drops it from the UI) and **refuses a primary workspace**.
- `run [<name>]` — run a named command from the workspace's `.casper.json` in a
  new visible terminal (defaults to the command named `run`). Not scoped under
  its own noun like the others, but still a workspace-targeted verb.

Every workspace-scoped command shares a `--workspace <id-or-name>` option,
defaulting to `$CASPER_WORKSPACE_ID` (set in every Casper terminal); this is why
plain `casper status set working` works with no flags inside a Casper terminal
but needs `--workspace` from anywhere else. The one deliberate exception is
`workspace current`: it answers "which workspace is *this* terminal", so it
reads `$CASPER_WORKSPACE_ID` only and takes no target option — outside a Casper
terminal it errors rather than defaulting to something.

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
(`progress clear`, `notify`, `browser open`, `diff open`) →
`{"workspace":"<id>"}`. `terminal new` carries `working-dir` (always) and
`command` (when given); `terminal list` carries only `working-dir` (it no longer
carries `command` — a terminal's launch command is a one-shot instruction, not
durable state); `workspace new`/`list`/`current` carry the worktree `path`
(`branch` omitted for a degenerate, non-Git space). On **error** it prints
`{"error":"<msg>"}` to stderr and exits **non-zero** — a command in error never
returns 0; validate CLI-side in `makeCommand()` where possible. ArgumentParser's
own output (`--help`, missing option, unknown flag) stays native.

Every id Casper emits — in this JSON, and in the injected `$CASPER_WORKSPACE_ID`
— is **lowercase**, its canonical external form (`UUID.casperID`); `--workspace`
matches an id **case-insensitively**, so an uppercase id from an older build
still resolves (a workspace *name* still matches exactly). Persisted state is
unaffected: `session.json` keeps Swift's native `Codable` UUID encoding.

### Per-repository config (`.casper.json`)

A repository customizes its workspaces with a `.casper.json` at its root, read
by `RepoConfig` (CasperCore). The user-facing schema is documented in
`README.md`; what follows is the design behind it.

**Namespaced and forward-compatible.** Everything sits under a `workspace` key
so later sections have a home, and unknown keys decode silently — a file already
carrying another tool's section still loads. A file that exists but cannot be
read or decoded is a hard error (`RepoConfigError` → `Invalid .casper.json: …`),
never a silent fallback to defaults: a typo in the config must be visible.

**`copyFiles` distinguishes absent from empty.** `nil` means "unspecified" and
the caller's built-in defaults apply (`.env`, `.env.local`); an explicit `[]`
means "copy nothing". Patterns are matched with `fnmatch(3)`
(`WorkspaceFileCopier`). An invalid entry fails workspace creation **before any
Git mutation**, so a bad config never leaves a half-made worktree behind.

**`scripts` holds two different kinds of thing.** The reserved names `setup` and
`teardown` (`RepoScripts.reservedNames`) are *lifecycle hooks*: run
automatically by `ScriptHookRunner`, never invocable by hand —
`resolveRunCommand` denies them and the spawn entry points are private to the
runner. Every other key is a *named command*, run on demand from the toolbar or
`casper run <name>`.

The two kinds are wrapped in **deliberately opposite** ways, because they want
opposite outcomes from the same shell:

- A named command wraps as `(\n<cmd>\n)\n[ $? -eq 0 ] && exit`. The subshell
  contains an `exit` (or a `set -e` failure) so it kills only the subshell; the
  trailing test then exits the interactive shell — closing the pane — **only**
  on success. A failure leaves a live prompt with the output still on screen.
- A hook wraps as `<cmd>\nexit $?`, so the shell exits carrying the command's
  status and libghostty emits the child-exit event that *is* the hook's
  completion signal. In both wraps the trailing part sits on its own line, so a
  `#` comment ending the user's command cannot swallow it.

**`setup` runs from `createLinkedWorkspace` only.** The call site is the guard
against re-running on restore or re-open, so there is no persisted "already ran"
flag. Exit 0 auto-closes its split; a non-zero exit keeps the split open and
flags the workspace `.error`. There is no rollback. **`teardown`** runs before
the worktree is pruned and, on the close path, *after* the merge — so its cwd is
still valid — and every outcome (success, non-zero, or the 30 s timeout)
proceeds to prune, because a broken cleanup script must never trap the user.

**The script menu is alphabetical.** `scripts` is a JSON object and
`JSONDecoder` does not preserve object key order, so file order is not
recoverable; `namedCommands()` sorts instead. Reformatting `scripts` to an array
to regain order is deliberately not done.

The child-exit-before-close ordering that all of the hook code rests on, and the
re-entrancy claim guarding the destroy paths, are recorded in [[repo-config]].

### Agent state & progress

Casper installs **no agent-hook mechanism** into any agent — no hook
installation, no hook socket, no `hooks` CLI. A workspace's agent state
(`agentState`, todo progress, the attention flag) comes from one of two places:
the explicit domain verbs above, which an agent (or any tool) running in a
Casper terminal calls itself (`casper status set …`, `casper progress set …`,
`casper notify …`) and which then hold authority for that workspace; or Casper's
own terminal scraping (see `agent-state-detection.md`). Casper **never launches
an agent**; the user runs their agent manually.

The only agent-facing runtime coupling is the per-surface environment
`AgentEnvironment.surfaceEnvironment` injects into every Casper terminal:
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

### Agent integration detection

Casper supports three coding agents — **Claude Code**, **OpenAI Codex CLI** and
**opencode** — and each reaches the CLI above through a plugin the user installs
into the agent itself. **Casper never writes another tool's configuration**:
every agent ships its own installer, so all Casper does is *detect* what an
installer left behind and remind the user when something is missing or stale.
There is deliberately no install, repair or enable action anywhere in the app —
writing a file Casper does not own makes it responsible for migrating one. See
[[agent-integration-policy]].

The probe is **global**: one answer per agent for the whole app, never per
workspace. "The user has Codex but not the integration" is a property of the
machine, not of a worktree, so there is nothing per-workspace to key it on.

Three layers, deliberately separated:

- `CasperCore/AgentIntegration.swift` — the **policy** half: the agent
  catalogue, the status vocabulary, the version comparison, and one pure parser
  per agent. It performs no I/O at all (no `FileManager`, `Process` or
  `ProcessInfo`), so every awkward input — a registry missing a key, a config
  full of comments, a version nobody can parse — is a plain unit test. All three
  input formats are owned by other projects and can change under us.
- `CasperCore/AgentIntegrationProbe.swift` — the **I/O** half: path
  construction, the order evidence is consulted in, and the few judgements that
  only exist once real files are involved. Every side effect goes through an
  injectable `Environment` (executable lookup, file contents, directory entries,
  home directory), so the whole resolution runs against in-memory fixtures.
- `CasperUI` — `AgentIntegrationReminders.swift` (scheduling, dismissals, the
  published list; `AppModel` only forwards) and
  `AgentIntegrationReminderView.swift` (the sidebar rows).

#### Status model

`AgentIntegrationStatus` has five cases, and the agent's own CLI gates all of
them:

- `notInstalled` — the agent's CLI is absent, so the user does not use this
  agent. Renders **nothing at all**, ever: advertising an integration for a tool
  someone never installed is pure noise. It also short-circuits everything else,
  so Casper reads not a single file for an agent the user does not have.
- `missing` — the CLI is present, a working integration is not.
- `outdated(installed:)` — installed, but below
  `AgentIntegration.requiredPluginVersion`.
- `installedAwaitingHookTrust` — Codex only: installed and current, but no hook
  approval is recorded, so nothing it installed actually runs. See *Codex hook
  trust* below.
- `installed` — installed and current; normally nothing to report.

CLI presence is resolved through the user's **interactive login shell**
(`LoginShellPath`, shared with the rest of CasperCore), not through the process
`PATH`. Casper is launched from Finder or the Dock, so its own `PATH` is the
bare launchd default — no Homebrew, no nvm, no `~/.local/bin`. Probing that
would report every agent `notInstalled` for exactly the people who have the
agents installed. **Interactive** is load-bearing: `-lc` is a login but
*non-interactive* shell, so zsh sources `.zshenv`, `.zprofile` and `.zlogin` and
never `.zshrc` — and `.zshrc` is where a great many users actually build their
`PATH`. bash splits its files differently rather than symmetrically: it reads
`~/.bashrc` **only** for an interactive *non-login* shell, so an interactive
login bash reads `~/.bash_profile` and stops. Reaching a bash user's `.bashrc`
therefore needs a rung of its own, `-i -c`; against bash, `-i -l -c` answers
exactly what `-l -c` answers. Probed the login-only way, `codex` reads as absent
for a user whose terminal resolves it fine at `~/.local/bin/codex`, which
short-circuits the whole agent to `notInstalled` — the one status that renders
nothing at all.

The shell is asked for its **`PATH`**, not for the location of a command: the
probe body is `/usr/bin/printenv PATH`, and command names are then resolved
against that search path in Swift — an executable **regular file**, since
`FileManager.isExecutableFile` is `access(X_OK)` and says yes to any searchable
directory. Asking an
interactive shell `which codex` or `command -v codex` instead would be worse
than the bug it fixes — an interactive shell also defines aliases and functions,
and both builtins report those. Against a `.zshrc` that defines a `codex`
*function*, `which` prints a multi-line function body and `command -v` prints
the bare word `codex`; neither is a path, and neither is something `Process`
could execute. Reading `PATH` and testing directories cannot produce that class
of answer.

`printenv` is an absolute external command with no shell syntax in it, so the
probe is dialect-independent whatever `$SHELL` is (fish, whose `$PATH` is a
list; nu; csh) — `PATH` is exported to every child. Only the *flags* are
dialect-specific, so three sets of them are tried in order, as separate
arguments, and their answers **unioned**:

- `-i -l -c` — interactive *and* login. The rung that sources zsh's `.zshrc`;
  bash on it reads `.bash_profile` and stops.
- `-i -c` — interactive, *not* login. The only rung that sources bash's
  `.bashrc`, and so the decisive one for every bash user. zsh sources `.zshrc`
  here too, which costs one spawn and changes nothing for zsh.
- `-l -c` — login only. Misses both rc files, but every shell accepts it.

`-c` alone follows only when all three produced nothing (`/bin/csh` and
`/bin/tcsh` reject `-l` outright, so they were broken before too). The union
means no rung's answer can be **shrunk** by another — even a `.zshrc` that
clobbers `PATH` instead of prepending can only add directories. It is not a
promise that resolution never returns less than a single login shell would: a
probe that never completes contributes only what its finished rungs found. The
process's own `PATH` is appended last, and a shell that rejects a flag set exits
non-zero (a `$SHELL` naming a shell that is not installed fails to spawn), so an
unknown shell degrades to no worse than before. `-i` is also not side-effect
free: an `exec tmux` guarded on `$TMUX` is a common rc-file line, and when it
fires that rung contributes nothing at all.

Output is parsed generously — every `/`-prefixed, `:`-separated component of
every line, deduplicated — because a shell that sources a profile prints
whatever the profile prints. **Order** is what keeps that safe: banners are
printed *before* `printenv` runs, so the real `PATH` line (the last one whose
components are all absolute) is emitted first and the leftovers of every other
line follow it. A banner, a MOTD or a `.zlogout` line can therefore still
contribute a directory — `https://docs.example.com` alone yields
`//docs.example.com` — but never one ranked ahead of a genuine `PATH` entry,
and resolution then demands an executable regular file, so what it contributes
is in practice nothing.

Two properties of that lookup shape everything downstream:

- **It is bounded.** `LoginShellPath.lookupTimeout` caps the **whole** probe
  rather than each spawn, and the terminate-watchdog arms on that one shared
  deadline. A profile that blocks outright — a hung network mount, an `nvm` or
  `conda` bootstrap waiting on the network, anything reading stdin — would
  otherwise hold its caller forever; the cap turns that into a cached "not
  found". Stdin is `/dev/null` for the same reason: an interactive rc file may
  `read`, and a child inheriting a terminal would block right past any watchdog
  — a `.zshrc` holding a bare `read` completes instantly against `/dev/null` and
  hangs forever otherwise. It matters beyond this feature: the same lookup runs
  on the main actor for `EditorLauncher`, where an unbounded wait is a frozen
  app. The abandoned worker thread is left to finish on its own, and the shell
  is terminated on the same deadline. Each rung publishes its components as it
  finishes, so an answer already in hand is kept rather than discarded along
  with the rung still in flight. What the timeout does cost is **permanent**:
  an abandoned probe's result is cached like any other, so the process is left
  on the bare launchd `PATH` until Casper is relaunched — deliberate, since
  re-probing would spawn shells again on every detection tick and a profile
  that blocks once blocks every time.
- **Every answer is cached for the process lifetime, misses included.** That is
  what makes re-probing cheap, and it is a deliberate trade-off with a visible
  cost: an agent CLI installed *while Casper is running* stays `notInstalled`
  until the next launch, and no amount of re-probing recovers it. Re-probing
  recovers plugin state — the files under `~/.claude`, `~/.codex`,
  `~/.config/opencode` are read fresh every time — never CLI presence.

#### Per-agent markers

**Claude Code.** `~/.claude/plugins/installed_plugins.json` maps a plugin id to
an **array** of install records, one per scope, each carrying a `version`. The
id is `casper@casper`; `AgentIntegration.legacyPluginID` (`casper@Casper`) is
matched as well and reports `outdated` whatever version it carries — a
compatibility branch for the pre-publication local dev install, not migration
support for a published plugin. The current id is consulted first, and versions
are never mixed across the two, since the registrations are separate installs.
Enablement lives separately, in `~/.claude/settings.json` under
`enabledPlugins`.

The two ids differ **by case alone**, which makes the registry key the only
usable evidence. `~/.claude/plugins/cache/casper/` and `…/cache/Casper/` are the
*same folder* on a case-insensitive volume — the APFS default — so anything
derived from a record's `installPath` would read a current install as legacy, or
the reverse, depending only on which install created the directory first. The
probe therefore reads the registry key and the record's `version` field and
nothing else. It also means both sides of every lookup must stay
case-**sensitive**: a `lowercased()` or `caseInsensitiveCompare` anywhere in
that path would collapse the two ids into one and lose the only signal that
tells a pre-rename install apart from a current one. A unit test pins that they
stay distinct-but-case-equal. (Codex is a different agent with a different
layout, and its cache path legitimately does carry the version.)

**opencode.** Two independent install shapes, either of which counts: a
`casper.js` file in `~/.config/opencode/plugin` or `…/plugins` (opencode's
loader globs both spellings), or a top-level `plugin[]` entry in
`~/.config/opencode/opencode.json` / `.jsonc` naming the npm package
`casper-skills` or a local `casper.js`. Both forms are matched *whole* rather
than by substring, so `@evil/casper-skills-fork` and `./plugin/notcasper.js` are
not mistaken for the integration. Despite the `.json` name the config format is
**JSONC**, and real files carry comments, so comments are stripped before
parsing — never inside a string literal, since opencode's own default config
holds `"$schema": "https://opencode.ai/config.json"`. The version exists only
inside a local plugin file, as `export const CASPER_PLUGIN_VERSION = "…"`; a
config-only install has none to read and is `installed`, not `outdated`.

**Codex.** Installs land in
`~/.codex/plugins/cache/<marketplace>/casper/<version>/`, so the version is a
path segment. Every marketplace is enumerated and every version directory
gathered before one winner is picked: `contentsOfDirectory` returns them in no
defined order, so stopping at the first would make the answer depend on
enumeration order. Dot-prefixed names are dropped first, so a directory left
behind holding nothing but a `.DS_Store` reads as an absent install rather than
as version `.DS_Store`. Disabled plugins are recorded in `~/.codex/config.toml`
as a `[plugins."casper@casper"]` section carrying `enabled = false`, matched by
a targeted five-line scan — a TOML dependency to read one boolean does not earn
its place under the dependency policy, and every limitation of the scan misses
in the safe direction (an unseen `enabled = false` reads as enabled, never the
reverse).

Two Codex traps, both able to produce a confidently wrong answer:

- **No plugin manifest is read.** The plugin repository ships only
  `.claude-plugin/plugin.json` and relies on Codex's manifest discovery order
  falling through to it, so probing by manifest file name matches nothing.
- **`~/.codex/hooks.json` is never evidence of anything**, and no code reads it.
  It appears on machines with no Codex installed at all — unrelated tools write
  to it — and the plugin never writes to it.

**The Codex cache layout is confirmed against a real Codex 0.149.0 install**:
`~/.codex/plugins/cache/casper/casper/0.2.0/`, the version being the leaf path
segment. That is the default Codex home, and the only one Casper builds paths
from — a `CODEX_HOME` override is not read. `codex plugin list --json` is the
stricter cross-check — it reports `pluginId`, `name`, `marketplaceName`,
`version`, `installed`, `enabled`, `source`, `marketplaceSource`,
`installPolicy` and `authPolicy`, and **no hook-trust field**, so it answers
"is it installed" and never "is it approved".
Its stdout can also carry trailing terminal escape bytes when a user's shell
wraps `codex` in a function, so a parser must read the first JSON document
rather than the whole stream. See [[codex-detection-caveats]].

#### Disabled is missing

An integration the user has **explicitly disabled** reports `missing`, not
`installed`: none of its hooks fire, so an install that is switched off is
functionally absent, and reporting it healthy would tell the user everything is
fine while nothing happens. Each tool records this in its own polarity — Claude
Code an enablement flag in `settings.json`, Codex a disabled flag in
`config.toml` — and both ids are consulted on the Claude side, so an explicit
`false` under either spelling switches the same integration off.

An **absent** key means enabled, never disabled. The map holds only the plugins
whose global state the user has actually touched, and enablement can also be set
per project, so a missing key is evidence of nothing. Unreadable or unexpected
JSON degrades to enabled for the same reason.

#### Never produce a false nag

The governing rule of the whole feature: a reminder the user did not need costs
more trust than one they missed. Everything ambiguous therefore resolves towards
silence.

- An installed integration whose version cannot be determined reports
  `installed`. That covers the literal `"unknown"` Claude Code records for a
  plugin whose manifest omits `version` (it occurs in real registries),
  pre-release suffixes, and outright garbage. An unreadable version is not
  evidence of a stale install.
- Every registry reports its version as an unordered set of candidates — one
  Claude record per scope, one Codex cache directory per marketplace — and the
  **highest** wins. Taking the first would turn "installed from two places, one
  of them stale" into a false `outdated`.
- The version comparison is numeric and component-wise (`0.10.0` beats `0.9.0`,
  `0.2` equals `0.2.0`), and the rule is `installed < required`, never `!=`: a
  user *ahead* of Casper's build is current, so a plugin release never forces a
  Casper release just to stop the nagging. See [[plugin-version-coupling]].
- A Codex `config.toml` that exists but will not read answers neither question
  it is consulted for, so it counts as *not disabled* and as *trusted*. Only a
  config that is genuinely absent — `~/.codex` does not list it — records no
  approval. A permissions problem on one file must not nag a user whose hooks
  are approved for the rest of the install's life.

#### Codex hook trust

Codex hashes non-managed command hooks and refuses to run them until the user
approves them through `/hooks` in its TUI. A Codex install can therefore be
complete on disk and do absolutely nothing.

That approval **is** recorded on disk, in the same `~/.codex/config.toml` the
disabled check reads, as one `[hooks.state]` table per hook keyed
`"<pluginId>:<hooks file>:<event>:<index>:<index>"`:

```toml
[hooks.state."casper@casper:hooks/hooks.json:session_start:0:0"]
trusted_hash = "sha256:63ef580c6830…"
enabled = true
```

The plugin's own entries are the ones prefixed `casper@casper:` — a hook
belonging to no plugin puts an absolute path where the id goes — and an entry
carrying an explicit `enabled = false` is switched off and does not count (an
absent `enabled` means enabled). A `trusted_hash` under that prefix means the
user has been through `/hooks`, and the notice stays off.

The quantifier is **any**, not *all*: one approved, enabled entry is enough.
Casper cannot know which hooks the installed plugin version ships, so "all of
them" is a set it has no way to enumerate, and a user who approved
`session_start` and switched `stop` off reads as trusted. That is the quiet
direction, and it keeps the notice to the one thing Casper can state honestly —
whether the user has ever been through `/hooks` for this plugin. The prefix
match is case-sensitive for the same reason the rest of the feature is, so the
legacy `casper@Casper:` spelling does not match.

Being a fact found on disk, it is a status: `installedAwaitingHookTrust`, the
fifth `AgentIntegrationStatus` case, reported when the install is current but no
approval is recorded. `installed` therefore means what it says for every agent,
Codex included, and the notice is shown to the users who need it instead of to
everyone.

**Casper does not recompute the hash.** Doing so would mean reproducing Codex's
hashing scheme, so a plugin update that invalidates a stored hash reads as
trusted here while Codex re-prompts. That false negative is deliberate, and in
the same direction as everything else on this page: staying quiet costs less
than asserting a trust problem the user usually does not have.

#### Reminders in the sidebar

`AppModel` publishes an ordered `agentIntegrationReminders` list, one line per
agent that has something to say: `missing`/`outdated` produce an *action-needed*
line, `installedAwaitingHookTrust` produces a *trust notice*, and `installed`
and `notInstalled` produce nothing. The mapping is an exhaustive switch,
so a new status case forces a decision rather than defaulting to silence, and
the list is driven by `CodingAgent.allCases` — dictionary order depends on a
per-process hash seed and would shuffle the rows between launches.

A dismissal silences the *current* problem, not the agent forever, so a status
that proves a problem gone retires the dismissal that silenced it — also an
exhaustive switch. The two lines have separate keys and separate retirements:
the action-needed dismissal goes as soon as the plugin is installed,
`installedAwaitingHookTrust` included, while the trust notice's own dismissal
survives that status and is retired by `installed` alone. Retiring it any
earlier would un-dismiss the notice the moment it became relevant; never
retiring it would silence a Codex user for good the first time the approval is
lost.

The probe runs **off the main actor**, always. A cold `statuses()` pays for the
`LoginShellPath` probe — up to three shell spawns, measured at ~0.5 s on a
machine with a populated `~/.zshrc` — on top of the file reads behind it, and a
shell profile is entitled to take seconds, so running it inline would freeze the
UI for that whole time.

`AppDelegate` starts exactly one probe at launch, and that is the only one that
pays the cold cost. Afterwards a **staleness check** rides the existing agent
detection tick: each pass calls `refreshAgentIntegrationsIfStale()`, which
re-probes once the last result is older than
`AppModel.agentIntegrationProbeInterval` — **five seconds**. It is a freshness
horizon, not a rate limiter: nothing is being protected from load, the answer is
simply not trusted past that age. The cadence is affordable precisely because of
the `LoginShellPath` cache above: every probe after the first spawns nothing at
all — a handful of `stat` and `read` calls, far too cheap to ration by the
minute. `applicationDidBecomeActive` applies the same check, so a Cmd-Tab storm
still probes at most once per interval.

Three rules hold the cadence together:

- **A tick never starts the *first* probe.** `shouldRefreshAgentIntegrations`
  answers `false` for a nil `lastProbeAt`: with no earlier result there is
  nothing to *re*fresh, and paying the cold login-shell cost stays the launch
  path's job. It also keeps every unit test that drives the detection tick off
  the real filesystem.
- **Seconds are what close the loop.** The expected way to install an
  integration is a `plugin install` command typed *in a Casper terminal*, which
  never resigns the app active — so activation alone fires no event at all, and
  nothing but this cadence can retire the line while the user is still watching
  for it.
- **Opening the documentation ages the result out.** Clicking a reminder row
  calls `agentReminderDocumentationOpened()`, which back-dates `lastProbeAt` to
  `.distantPast` so the very next check re-probes instead of leaving the line up
  for the rest of the interval. An install is imminent at that moment; the user
  has earned the fresh answer.

`refreshAgentIntegrations()` is the un-throttled entry point behind both paths.
A probe already in flight is left to finish rather than joined by a second one,
and the task is cancelled on teardown — `Task.detached` neither inherits nor
forwards cancellation, so a cancelled probe still runs to completion and the
`Task.isCancelled` check on the way back is what stops it publishing.

See [[agent-integration-probe-cadence]].

The rows sit between the scrolling workspace list and the "Add Folder…" footer,
and render **nothing at all** — no divider, no padding, no container — when
there is nothing to say, which is most of the time. They stay advisory in tone
(no destructive red) because Casper nudges and never repairs. The row button and
the dismiss button are **siblings**, never nested, so a dismiss click cannot
also open the documentation URL.

An outdated row **names the installed version**: `Claude Code integration is
outdated (0.1.0)`. It is the one detail that makes a nag someone believes is
wrong diagnosable from a screenshot. The version is whatever another tool wrote
down — a Codex cache *directory name*, or a Claude registry field that is
legitimately the literal `"unknown"` — so nothing guarantees it is short or
sane: whitespace runs collapse to single spaces (a newline mid-message would
burn a whole row line on a hard break) and the result is capped at
`maxDisplayedVersionLength`, after which the row drops the parenthesis entirely
rather than showing an empty one. The other two lines carry
no version: `<agent> integration not installed` and, for Codex,
`Codex integration needs approval`.

A dismissal is persisted in `Session.dismissedAgentReminders` (encoded as a
sorted array, so an unchanged session serialises identically across launches)
under `CodingAgent.reminderID` — stable strings spelled out independently of the
enum's `rawValue`, so renaming a case can never silently invalidate a dismissal
the user already made. It silences the *current problem, not the agent*: as soon
as an agent reports its integration installed — approved or awaiting approval —
its action-needed dismissal is retired, so a later regression reminds again
instead of staying silent for good. The trust notice carries a key of its own
(`<id>-trust`) precisely because it appears under a status the auto-clear treats
as healthy; sharing the key would un-dismiss it the instant it became relevant.
