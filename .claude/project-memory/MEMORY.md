# Project Memory

> When a new decision **contradicts** an existing memory note, do NOT silently
> override it. Instead: surface the conflict, quote the existing memory, explain
> how the new decision differs, and ask for explicit confirmation before
> updating. **Do NOT take any action** — no tool calls, no file writes — until
> confirmed.

- [Dependency policy](references/dependency-policy.md) — default to native macOS APIs (check the OS before reinventing/importing); only GhosttyKit + swift-argument-parser + libgit2
- [libgit2 Swift interop](references/libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [libgit2 untracked diff content flag](references/libgit2-untracked-content.md) — GIT_DIFF_SHOW_UNTRACKED_CONTENT required or untracked text misflags binary + badge undercounts
- [libgit2 linker warning](references/libgit2-linker-warning.md) — the macOS-26-vs-15 ld warning from Homebrew's libgit2 is benign; left unsuppressed on purpose
- [Dual-axis ScrollView centering](references/dual-axis-scrollview-centering.md) — a both-axes SwiftUI ScrollView centers undersized content; pin it top-leading via measured viewport size
- [Test toolchain](references/test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [Swift toolchain floor](references/swift-toolchain-floor.md) — code uses Swift 6.2 isolated conformances; CI/release Xcode pin must stay >= 26 (currently 26.3)
- [Git workflow](references/git-workflow.md) — explicit authorization before git init/commit/push
- [SDD doc location](references/sdd-doc-location.md) — new design/plan docs go in gitignored `.superpowers/sdd/`, not `docs/superpowers/specs/`
- [Commit message style](references/commit-message-style.md) — verb + action performed, always in English
- [English only](references/english-only.md) — all generated text (docs, code, UI) must be in English
- [Swift 6 Network concurrency](references/swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [FSEvents DirectoryWatcher gotchas](references/fsevents-directory-watcher.md) — no IgnoreSelf (drops in-process writes), realpath-canonicalize paths, barrier stop()
- [Diff refresh uses two FSEvents watchers](references/diff-refresh-two-watchers.md) — worktree watcher (excl. .git) + reflog watcher on <gitdir>/logs; second one refreshes diff after commit
- [Domain CLI and control channel](references/domain-cli-control-channel.md) — domain CLI emits JSON over `$CASPER_CONTROL_SOCKET` (verbs + shapes, errors exit non-zero); no hook mechanism
- [App sessions (--session)](references/app-sessions.md) — `--session <name>` suffixes layout+sockets and sets `CASPER_SESSION`; live-verify the GUI under session `dev` to isolate from the real instance
- [CLI availability](references/cli-availability.md) — no global install/shim; reachable only in Casper terminals via PATH injection
- [GhosttyKit / libghostty pin](references/ghosttykit-pin.md) — Lakr233/libghostty-spm 1.2.8 = Ghostty v1.3.1; GhosttyKit product only; vendored header via vendir
- [Debug channel and logging gating](references/debug-channel-gating.md) — debug control channel is `#if DEBUG` only, never in release; verbose logs gated, `.error`/`.fault` kept
- [Ghostty Metal layer contentsScale](references/ghostty-layer-contents-scale.md) — sync layer.contentsScale to window.backingScaleFactor or the render upscales ×2
- [libghostty key encoding](references/ghostty-key-encoding.md) — Ctrl-combos need unshifted_codepoint on the key event; keycode+mods alone emits nothing
- [Implementation workflow](references/implementation-workflow.md) — execute plans subagent-driven: one code-writer per task, review between, commit per task
- [e2e surface creation flakiness](references/e2e-surface-creation-flakiness.md) — `ghostty_surface_new` can return null in some sessions; verify via git-stash-to-baseline before blaming code
- [libghostty clipboard callbacks](references/ghostty-clipboard-callbacks.md) — userdata is per-surface (the view), callbacks run on main thread, confirmed binding action names, Swift 6 pointer-sending fix
- [Ghostty option-as-alt](references/ghostty-option-as-alt.md) — translation-mods wiring added; pinned binary's config effect on it is unconfirmed e2e
- [libghostty mouse handling parity](references/ghostty-mouse-parity.md) — multi-click is core-side (no click-count param); tracking-area position stream drives it; mouse-shape/visibility actions are surface-scoped via `ghostty_surface_userdata`
- [libghostty scroll mods packed layout](references/ghostty-scroll-mods-layout.md) — opaque `int` = packed i32: bit 0 precision (else pixels read as lines → scroll too fast), bits 1–3 momentum
- [Surface identity](references/surface-identity.md) — every Surface has a unique, stable `Surface.id` invariant across kind/state/UI-location; all UI identity (view cache, `.id`, focus) anchors on it
- [Observed startup dependencies](references/observed-startup-dependencies.md) — startup-set @Observable props a view gates rendering on must not be @ObservationIgnored; live-verify the restore path
- [PersistentNSViewHost shared-view ownership](references/persistent-nsview-host-sharing.md) — one cached NSView per surface; a window-membership-driven coordinator converges it into the in-window container (splits, collapses, drag-relocate); do not revert to the one-shot deferred reconcile
- [Custom resizable inspector panel](references/swiftui-inspector-width.md) — Casper hand-rolls the inspector (native .inspector aborts on macOS 26 drag); custom HStack + absolute-location divider; always-mounted, revealed by trailing clip width (not a .move transition, which lags the AppKit tab Picker)
- [Intra-app drag pasteboard type](references/intra-app-drag-pasteboard-type.md) — pane drag-drop transports over standard `public.utf8-plain-text`; a code-only custom UTType is ignored by SwiftUI .onDrop (no Info.plist)
- [Debug screenshot uses ScreenCaptureKit](references/debug-screenshot-screencapturekit.md) — macOS 15 target obsoletes CGWindowListCreateImage; DEBUG screenshot uses async SCScreenshotManager + screen-recording permission
- [Ghostty is the reference implementation](references/ghostty-is-the-reference.md) — for native macOS terminal UI/interaction features, match Ghostty's macOS Swift source instead of improvising
- [Cursor management for chrome over the terminal](references/terminal-overlay-cursor.md) — overlays set the cursor via cursorUpdate AND mouseEntered, reset to arrow on exit; never push/pop or addCursorRect alone; splitter uses SplitterHandleView (not .pointerStyle)
- [Driving the Casper GUI with synthetic mouse input](references/casper-gui-synthetic-input.md) — no debug mouse verb; use CGEvent but make the window key first, park cursor off-window for clean captures
- [Browser address bar select-all on click](references/browser-address-bar-select-all.md) — field is already first-responder on tab show; select-all in NSTextField.mouseDown after super (not on focus transition), gated on empty selection
- [UNUserNotificationCenter aborts unbundled](references/unusernotificationcenter-unbundled-abort.md) — `UNUserNotificationCenter.current()` aborts (no bundle id) under `make dev`; guard `deliverNotification` on `Bundle.main.bundleIdentifier`
- [ArgumentParser Optional default](references/argumentparser-optional-default.md) — `@Option var x: String?` needs explicit `self.x = nil` in `init()` or direct construction (tests) crashes
