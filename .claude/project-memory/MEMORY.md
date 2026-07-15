# Project Memory

> When a new decision **contradicts** an existing memory note, do NOT silently
> override it. Instead: surface the conflict, quote the existing memory, explain
> how the new decision differs, and ask for explicit confirmation before
> updating. **Do NOT take any action** — no tool calls, no file writes — until
> confirmed.

- [Dependency policy](references/dependency-policy.md) — default to native macOS APIs (check the OS before reinventing/importing); only GhosttyKit + swift-argument-parser + libgit2 + HighlightSwift
- [libgit2 Swift interop](references/libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [libgit2 untracked diff content flag](references/libgit2-untracked-content.md) — GIT_DIFF_SHOW_UNTRACKED_CONTENT required or untracked text misflags binary + badge undercounts
- [libgit2 linker warning](references/libgit2-linker-warning.md) — the macOS-26-vs-15 ld warning from Homebrew's libgit2 is benign; left unsuppressed on purpose
- [Dual-axis ScrollView centering](references/dual-axis-scrollview-centering.md) — a both-axes SwiftUI ScrollView centers undersized content; pin it top-leading via `.defaultScrollAnchor(.top)`
- [Test toolchain](references/test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [Swift toolchain floor](references/swift-toolchain-floor.md) — code uses Swift 6.2 isolated conformances; CI/release Xcode pin must stay >= 26 (currently 26.3)
- [Git workflow](references/git-workflow.md) — explicit authorization before git init/commit/push
- [SDD doc location](references/sdd-doc-location.md) — new design/plan docs go in gitignored `.superpowers/sdd/`, not `docs/superpowers/specs/`
- [English only](references/english-only.md) — all generated text (docs, code, UI, commit messages) is English; commit subjects use verb + action
- [Swift 6 Network concurrency](references/swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [FSEvents DirectoryWatcher gotchas](references/fsevents-directory-watcher.md) — no IgnoreSelf (drops in-process writes), realpath-canonicalize paths, barrier stop()
- [Diff refresh uses two FSEvents watchers](references/diff-refresh-two-watchers.md) — worktree watcher (excl. .git) + reflog watcher on <gitdir>/logs; second one refreshes diff after commit
- [Per-workspace diff summary is dropped](references/space-diff-summary-dropped.md) — the Space +/− branch-vs-merge-base row badge is not built; only Space rename remains open
- [Domain CLI and control channel](references/domain-cli-control-channel.md) — domain CLI emits JSON over `$CASPER_CONTROL_SOCKET` (verbs + shapes, errors exit non-zero); no hook mechanism
- [ArgumentParser Optional default](references/argumentparser-optional-default.md) — a custom `init()` assigning `@Option`/`@Argument` wrapped values crashes real `.parse()`; test via `.parse([...])`, not direct construction
- [App sessions (--session)](references/app-sessions.md) — `--session <name>` (DEBUG builds only) suffixes layout+sockets and sets `CASPER_SESSION`; live-verify the GUI under session `dev` to isolate from the real instance
- [CLI availability](references/cli-availability.md) — no global install/shim; reachable only in Casper terminals via PATH injection
- [GhosttyKit / libghostty pin](references/ghosttykit-pin.md) — Lakr233/libghostty-spm 1.2.8 = Ghostty v1.3.1; GhosttyKit product only; vendored header via vendir
- [libghostty initial_input mojibakes non-ASCII](references/ghostty-initial-input-utf8.md) — don't use `initial_input` (or the `command` field); inject queued input via `ghostty_surface_text` (UTF-8-safe) post-spawn
- [Debug channel and logging gating](references/debug-channel-gating.md) — debug control channel is `#if DEBUG` only, never in release; verbose logs gated, `.error`/`.fault` kept
- [Ghostty Metal layer contentsScale](references/ghostty-layer-contents-scale.md) — sync layer.contentsScale to window.backingScaleFactor or the render upscales ×2
- [libghostty Control-combo key encoding](references/ghostty-key-encoding.md) — Ctrl-combos need unshifted_codepoint; bare Control-letter combos also need the keycode normalized to its QWERTY position (AZERTY)
- [Implementation workflow](references/implementation-workflow.md) — execute plans subagent-driven: one code-writer per task, review between, commit per task
- [e2e surface creation flakiness](references/e2e-surface-creation-flakiness.md) — `ghostty_surface_new` can return null in some sessions; wake the display + poll, or verify build-only
- [libghostty clipboard callbacks](references/ghostty-clipboard-callbacks.md) — userdata is per-surface (the view), callbacks run on main thread, confirmed binding action names, Swift 6 pointer-sending fix
- [Ghostty option-as-alt](references/ghostty-option-as-alt.md) — translation-mods wiring; pinned binary's config effect on it is unconfirmed e2e
- [libghostty mouse handling parity](references/ghostty-mouse-parity.md) — multi-click is core-side (no click-count param); tracking-area position stream drives it; mouse-shape/visibility actions are surface-scoped via `ghostty_surface_userdata`
- [libghostty scroll mods packed layout](references/ghostty-scroll-mods-layout.md) — opaque `int` = packed i32: bit 0 precision (else pixels read as lines → scroll too fast), bits 1–3 momentum
- [Surface identity](references/surface-identity.md) — every Surface has a unique, stable `Surface.id` invariant across kind/state/UI-location; all UI identity anchors on it
- [Observed startup dependencies](references/observed-startup-dependencies.md) — startup-set @Observable props a view gates rendering on must not be @ObservationIgnored; live-verify the restore path
- [PersistentNSViewHost shared-view ownership](references/persistent-nsview-host-sharing.md) — one cached NSView per surface; a window-membership-driven coordinator converges it into the in-window container (splits, collapses, drag-relocate)
- [Custom resizable inspector panel](references/swiftui-inspector-width.md) — Casper hand-rolls the inspector (native .inspector aborts on macOS 26 drag); custom HStack + absolute-location divider; always-mounted, revealed by trailing clip width
- [Intra-app drag pasteboard type](references/intra-app-drag-pasteboard-type.md) — pane drag-drop transports over standard `public.utf8-plain-text`; a code-only custom UTType is ignored by SwiftUI .onDrop (no Info.plist)
- [Debug screenshot uses ScreenCaptureKit](references/debug-screenshot-screencapturekit.md) — macOS 15 target obsoletes CGWindowListCreateImage; DEBUG screenshot uses async SCScreenshotManager + screen-recording permission
- [Agents cannot self-verify SwiftUI visual changes](references/agent-visual-verification-limits.md) — subagents lack screen-recording TCC even when the session's own terminal has it; visual polish needs human screenshots
- [glassEffect renders invisible with a nested Menu](references/glasseffect-nested-menu-invisible.md) — a native Menu mid-hierarchy breaks glassEffect's compositing; use explicit Color background + strokeBorder instead
- [Ghostty is the reference implementation](references/ghostty-is-the-reference.md) — for native macOS terminal UI/interaction features, match Ghostty's macOS Swift source instead of improvising
- [Cursor management for chrome over the terminal](references/terminal-overlay-cursor.md) — overlays set the cursor via cursorUpdate AND mouseEntered, reset to arrow on exit; never push/pop or addCursorRect alone
- [Driving the Casper GUI with synthetic mouse input](references/gui-synthetic-input.md) — no debug mouse verb; use CGEvent but make the window key first, park cursor off-window for clean captures
- [Browser address bar select-all on click](references/browser-address-bar-select-all.md) — field is already first-responder on tab show; select-all in NSTextField.mouseDown after super, gated on empty selection
- [UNUserNotificationCenter aborts unbundled](references/unusernotificationcenter-unbundled-abort.md) — aborts with no bundle id; `make dev` has one via Casper-dev.app, so notifications work; guard on `Bundle.main.bundleIdentifier` stays
- [macOS notification sound cache bug](references/macos-notification-sound-cache-bug.md) — custom sound falls back to default; OS-level bug, not signing; fix is reboot+reinstall, not code
- [MainActor isolated delegate conformance](references/mainactor-isolated-delegate-conformance.md) — a @MainActor class conforming to a non-@MainActor Cocoa delegate needs `@MainActor` on the conformance; @MainActor-annotated protocols don't
- [Agent-state working signal lives in the OSC title](references/agent-state-osc-title.md) — Claude Code signals working via OSC-title Braille spinner; pinned libghostty fork forwards titles; detection is version-coupled
- [libghostty macOS config dir is bundle-id scoped](references/ghostty-config-dir-bundle-id.md) — bundled Casper.app misses the user's Ghostty config (empty bundle-id-scoped dir) → vanilla gray; hence the baked-in default theme
- [Headless merge leaves the base worktree dirty](references/headless-merge-worktree-dirty.md) — after mergeBranchHeadless the base worktree reports deleted files; capture cleanliness before merging to decide any resync
- [Test isolation from Casper socket env vars](references/test-env-socket-isolation.md) — `make test` strips CASPER_CONTROL_SOCKET/CASPER_DEBUG_SOCKET/CASPER_SESSION so a Casper-opened terminal's live env never leaks into swift test
- [Socket listen-path vs dial-path resolution](references/socket-listen-vs-dial-path.md) — App must bind via `listenPath(for:)` (session-only); `resolve(for:)`/`.default` (env-override) is dial-only or it hijacks a running instance's socket
- [Real in-process GhosttySurfaceView e2e harness](references/ghostty-real-surface-e2e-harness.md) — real keyDown->interpretKeyEvents->shell test recipe; fixed settle(0.6)/(0.4), not adaptive polling
- [SwiftUI owns the main menu](references/swiftui-mainmenu-miniaturize-resync.md) — menu bar is `.commands`; empty Format/Help stubs stripped on will+didUpdate; the `.commands` body must not observe volatile focus/spaces → edge-triggered enable flags + always-enabled Split
- [HighlightSwift resource bundle placement](references/highlightswift-resource-bundle.md) — Bundle.module checks only the .app root + a machine-local build path, never Contents/Resources; the runtime mirror is required, not redundant
- [Diff-view refresh hang (open incident)](references/diff-view-refresh-hang.md) — unreproduced SwiftUI-layout beachball on diff refresh; a `diff refresh:` .notice log line catches the next occurrence; don't nest a LazyVStack in DiffFileView
- [Workspace selection invariant](references/workspace-selection-invariant.md) — non-empty `spaces` always has a resolvable `selectedWorkspaceID`; homepage shows only when `spaces.isEmpty`; watch `selectWorkspace` sets-before-validates
- [.casper.json scripts — design decisions & invariants](references/repo-config.md) — copyFiles + named commands + setup/teardown hooks: the child-exit/close race invariant, hook-wrap vs subshell-wrap, completion-based destroy, menu ordering
- [Project memory conventions](references/project-memory-conventions.md) — don't prefix memory filenames with `casper`; implementation status goes in `.superpowers/status.md`, not memory (durable decisions only)
- [Avoid isolated deinit on @MainActor classes](references/isolated-deinit-ci-sigabrt.md) — its back-deploy shim SIGABRTs under XCTest on CI; use plain deinit + nonisolated(unsafe)
- [libghostty set_occlusion param is `visible` not `occluded`](references/ghostty-set-occlusion-visible-polarity.md) — false pauses the render thread; inverting it freezes visible surfaces (grid still updates, no frames)
- [titleCapsule() hit area on plain buttons](references/title-capsule-hit-area.md) — apply .titleCapsule() inside the Button's label, not after .buttonStyle(.plain), or only the glyph is clickable
- [Browser automation CLI](references/browser-automation-cli.md) — casper browser automation + console/wait/reload verbs: JS-synthesized input, takeSnapshot, off-screen behavior, WeakScriptMessageHandler retain-cycle proxy, control-socket-in-$TMPDIR gotcha
