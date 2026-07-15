---
name: "Browser automation CLI"
description: "casper browser automation + debug verbs: JS-synthesized input, WKWebView.takeSnapshot, off-screen behavior, the WKScriptMessageHandler retain-cycle proxy, and the control-socket-in-TMPDIR gotcha"
type: project
---

# Browser automation CLI

`casper browser` drives the workspace's inspector `WKWebView` through verbs beyond
`open`/`close`, all on the **release control channel**
([[domain-cli-control-channel]]) so they ship in every build:

- Automation: `screenshot [--out]`, `eval <js> [--raw]`, `content [--selector]
  [--raw]`, `click <selector>`, `type <selector> <text>`, `key <key> [--selector]`.
- Debug: `console [--level L] [--clear]`, `wait <selector>|--js <expr>
  [--visible|--gone] [--timeout ms]`, `reload [--wait]`.

Add a new verb the same way as any control verb: `ControlCommand.Verb` case + flat
field(s) + async completion-reply `ControlServer` dispatch + `AppModel.controlBrowser*`
+ `BrowserCommand` subcommand + JSON output. Pure JS generation lives in the
WebKit-free, unit-testable `BrowserAutomation` module.

## Design decisions (the durable "why")

- **Input is JS-synthesized, not real OS events.** `click`/`type`/`key` build a JS
  snippet (`querySelector` + `.click()` / set `.value` + dispatch `input`+`change` /
  dispatch `keydown`+`keyup`) run via `evaluateJavaScript`. Chosen over
  `NSEvent`/`CGEvent` synthesis because it is deterministic, needs no window focus
  or coordinate mapping, and works while the panel is collapsed or off-screen.
  Trade-off: it drives the DOM, not the real input stack (`type` sets `.value` and
  fires events; it does not emit per-character key events).
- **Screenshot uses `WKWebView.takeSnapshot`**, not ScreenCaptureKit — no
  screen-recording permission, captures rendered web content (not address-bar
  chrome), works off-screen. Distinct from the DEBUG terminal screenshot
  ([[debug-screenshot-screencapturekit]]). Plain `screenshot` snapshots the live
  browser web view (panel size when mounted; 1280×800 fallback when detached).
  `screenshot --width/--height [--url]` renders in a **dedicated off-screen
  `WKWebView`** (`BrowserCapture`) sized to the given viewport, so it captures
  responsive layouts regardless of panel state (a 375-wide capture triggers the
  page's mobile media query). `--url` captures an arbitrary URL headlessly; the
  capturer shares the `.default()` data store (cookies/localStorage carry), hosts
  the view in an off-screen `NSWindow` at `(-100000,-100000)`, waits for `didFinish`,
  and does a **fresh load** — so the live DOM's client-side state (SPA route,
  unsaved input) is not reproduced, only the URL's page. Raw dimensions only: no
  user-agent / devicePixelRatio emulation.
- **`load <url>` vs `open <url>`:** both point the single inspector browser surface
  at a URL and reuse its cached coordinator, but `open` also
  `setInspectorTab(.browser)` (selects the tab + expands the panel) while `load`
  does not touch the inspector tab/collapsed state — a background navigation.
  Because a hidden panel's `WKWebView` is never mounted, `load` must
  create-or-navigate the coordinator itself.
- **Off-screen support:** the verbs get-or-create the inspector browser's
  `BrowserCoordinator` themselves, so automation does not require the panel to be
  visible. `snapshot()` assigns a default 1280×800 frame **only when
  `webView.window == nil`**; it must not touch a mounted view's frame, or it races
  SwiftUI layout.
- **JS injection safety:** selectors/text are embedded as JSON string literals
  (`JSONSerialization`), which also escapes `/` so `</script>` can't break the
  script context.
- **Console capture** is an `.atDocumentStart` `WKUserScript` that wraps `console.*`
  and adds `error` + `unhandledrejection` listeners via `addEventListener` (never
  `window.onerror =`, which would clobber a page's own handler / Sentry) posting to
  a `casperConsole` message handler. Buffer is a 500-entry ring (drop oldest).
  `--clear` drains the whole buffer unconditionally; `--level` is a severity
  threshold. `ConsoleEntry`/`ConsoleLevel` (`debug<log<info<warn<error`,
  `Comparable`) live in CasperCore; the array rides in `ControlResponse.text` as a
  JSON string.
- **`wait`** polls `evaluateJavaScript("!!(\(predicate))")` ~every 100 ms via async
  `Task.sleep` (main actor not blocked) until truthy or the app-side deadline. A
  throwing predicate counts as not-yet-true, so a malformed predicate surfaces as a
  timeout. The CLI sends `selector`+`--visible`/`--gone` or `--js`; the app builds
  the predicate (`BrowserAutomation.presenceJS`/`visibleJS`/`goneJS`/
  `readyStateCompleteJS`). CLI socket timeout is `waitTimeout/1000 + 5` to outlive
  the app deadline.
- **Output:** `eval` → `{"result":<json>,…}`; `content` → `{"content":"<html>",…}`;
  `screenshot` → `{"screenshot":"<path>",…}`; action verbs → `{"workspace":…}`.
  `--raw` prints the bare value/HTML. A no-match selector / JS error / unwritable
  path → `{"error":…}`, non-zero exit.

## WKScriptMessageHandler retain-cycle gotcha

`WKUserContentController` retains its message handlers **strongly**, and the
coordinator owns `webView → config → userContentController`, so registering the
coordinator itself as the handler forms an inescapable cycle. A tiny
`WeakScriptMessageHandler: NSObject, WKScriptMessageHandler` proxy holds the
coordinator **weakly** and forwards `message.body`; the weak back-reference is the
entire fix. `WKScriptMessageHandler` is `@MainActor` in the SDK, so the proxy's
callback runs on the main actor ([[mainactor-isolated-delegate-conformance]]).
`BrowserCoordinator` deliberately has **no `deinit`** and does not store the
`WKUserContentController` — a `@MainActor`-only API like
`removeAllScriptMessageHandlers()` has no clean deinit home (the project's deinit
discipline forbids `isolated deinit` and `assumeIsolated`, see
[[isolated-deinit-ci-sigabrt]]), and it is redundant given the weak proxy. The
console ring buffer is private; a `#if DEBUG` `debugAppendConsole` seam makes the
cap/threshold/drain behaviour unit-testable without a live page.

## Off-screen / background caveats (measured)

A detached (`window == nil`) `WKWebView`'s content process runs regardless of
window attachment, so `eval`/`content`/`click`/`type`/`console`/`wait`/`screenshot`
all work on a non-selected workspace whose browser was never shown. But:

- A detached view reports `document.visibilityState === "hidden"`, so a page that
  gates work on visibility idles in the background.
- WebKit throttles recurring timers to ~1 Hz when hidden (a 100 ms `setInterval`
  advances ~2 ticks in 3 s); `requestAnimationFrame` is paused. A short one-shot
  `setTimeout` near load still fires on time — budget `wait --timeout` accordingly.

Bottom line: solid for DOM-driven automation; unreliable for anything driven by
real-time timers / rAF / visibility while off-screen.

## Live-driving gotcha

The CLI dials `$CASPER_CONTROL_SOCKET`, whose path comes from
`NSTemporaryDirectory()`, which **ignores a `TMPDIR=/tmp` override** — the control
socket lands in the per-user Darwin temp dir (`$TMPDIR`, e.g.
`/var/folders/.../T/casper-control-<session>.sock`), NOT `/tmp`. (The DEBUG debug
socket is hard-coded to `/tmp`, so the two live in different directories under a
named session.) A fresh `--session` starts with an empty layout; to bootstrap a
workspace non-interactively, pre-seed
`~/Library/Application Support/Casper/session-<name>.json` (a Space + Workspace
with a real `worktreePath`) before launch — `addSpace` is otherwise GUI-only
(`NSOpenPanel`).
