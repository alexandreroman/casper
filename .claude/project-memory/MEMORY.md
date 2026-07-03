# Project Memory

> When a new decision **contradicts** an existing memory note, do NOT silently
> override it. Instead: surface the conflict, quote the existing memory, explain
> how the new decision differs, and ask for explicit confirmation before
> updating. **Do NOT take any action** — no tool calls, no file writes — until
> confirmed.

- [Dependency policy](references/dependency-policy.md) — default to native macOS APIs (check the OS before reinventing/importing); only GhosttyKit + swift-argument-parser + libgit2
- [libgit2 Swift interop](references/libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [Test toolchain](references/test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [Git workflow](references/git-workflow.md) — explicit authorization before git init/commit/push
- [Commit message style](references/commit-message-style.md) — verb + action performed, always in English
- [English only](references/english-only.md) — all generated text (docs, code, UI) must be in English
- [Swift 6 Network concurrency](references/swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [Hooks install once](references/hooks-install-once.md) — hooks installed once GLOBALLY (~/.claude/settings.json) via CLI or at app startup, not per worktree; `hooks feed` relays
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
- [Surface identity](references/surface-identity.md) — every Surface has a unique, stable `Surface.id` invariant across kind/state/UI-location; all UI identity (view cache, `.id`, focus) anchors on it
- [Observed startup dependencies](references/observed-startup-dependencies.md) — startup-set @Observable props a view gates rendering on must not be @ObservationIgnored; live-verify the restore path
- [PersistentNSViewHost shared-view collapse gotcha](references/persistent-nsview-host-sharing.md) — one cached NSView per surface; a layout collapse can let a stale host steal it, blanking the survivor — window-guarded deferred reconcile guards it
- [SwiftUI native inspector width persistence](references/swiftui-inspector-width.md) — inspector column width is scene-level; measure via root GeometryReader+onChange, restore via ideal, re-seed per workspace with .id
