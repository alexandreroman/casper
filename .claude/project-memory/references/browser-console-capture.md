---
name: "Browser console/wait/reload + WKScriptMessageHandler retain cycle"
description: "console capture wiring and the WeakScriptMessageHandler proxy that breaks WKUserContentController's strong retain of its handler"
type: project
---

# Browser console/wait/reload + WKScriptMessageHandler retain cycle

`casper browser` gains three debug verbs beyond the six automation ones
([[browser-automation-cli]]): `console [--level L] [--clear]`,
`wait <selector>|--js <expr> [--visible|--gone] [--timeout ms]`, and
`reload [--wait]`. Wired the same way as any control verb (`ControlCommand.Verb`
case + flat fields + async completion-reply dispatch + `AppModel.controlBrowser*`
+ `BrowserCommand` subcommand + JSON output). `ConsoleEntry` / `ConsoleLevel`
(severity `debug<log<info<warn<error`, `Comparable`) live in CasperCore for a
typed contract; the console array rides in `ControlResponse.text` as a JSON
string (no new response fields).

## Durable decisions

- **Console capture** is a `.atDocumentStart` `WKUserScript` that wraps
  `console.*` and adds `error` + `unhandledrejection` listeners
  (`addEventListener`, never `window.onerror =`), posting each entry to a
  `casperConsole` message handler. Using `addEventListener("error", …)` avoids
  clobbering (and being clobbered by) a page's own `window.onerror` — error SDKs
  like Sentry assign it — and also catches resource-load errors. Buffer is a
  500-entry ring (drop oldest). `--clear` drains the WHOLE buffer unconditionally
  (never the filtered subset). `--level` is a severity threshold
  (`--level warn` → warn+error).
- **`wait`** polls `evaluateJavaScript("!!(\(predicate))")` ~every 100 ms via
  async `Task.sleep` (main actor not blocked) until truthy or the app-side
  deadline. A predicate that throws counts as not-yet-true, so a malformed
  predicate surfaces as a timeout. The CLI sends `selector`+`--visible`/`--gone`
  or `--js`; the APP builds the predicate JS (`BrowserAutomation.presenceJS/
  visibleJS/goneJS/readyStateCompleteJS`, pure + unit-tested). CLI sets the socket
  timeout to `waitTimeout/1000 + 5` so it outlives the app deadline.

## WKScriptMessageHandler retain-cycle gotcha (the non-obvious part)

`WKUserContentController` retains its message handlers **strongly**, and the
coordinator owns `webView → config → userContentController`. Registering the
coordinator itself as the handler forms a cycle it can never escape. Fix: a tiny
`WeakScriptMessageHandler: NSObject, WKScriptMessageHandler` proxy holds the
coordinator **weakly** and forwards `message.body`. The weak back-reference is
the *entire* fix — nothing strong points back at the coordinator, so it
deallocs (tearing down `webView → config → controller → proxy` with it) with no
leak. `WKScriptMessageHandler` is `@MainActor` in the SDK, so the proxy's
callback runs on the main actor ([[mainactor-isolated-delegate-conformance]]).

`BrowserCoordinator` deliberately has **no `deinit`** and does **not** store the
`WKUserContentController`. An earlier belt-and-braces
`removeAllScriptMessageHandlers()` in a plain `deinit` (reading the controller
through a `nonisolated(unsafe)` stored `let`) was removed: it was redundant given
the weak proxy above, and the newer Swift compiler warns on the call — `removeAll`
is `@MainActor`, so it can't be invoked from a nonisolated `deinit`, and the
project's deinit discipline forbids both escape hatches (`isolated deinit`
SIGABRTs on CI, `assumeIsolated` is unsafe in a deinit not guaranteed to run on
the main actor — see [[isolated-deinit-ci-sigabrt]]). Note that discipline covers
only nonisolated thread-safe cleanup (`NSEvent.removeMonitor`, `NotificationCenter.
removeObserver`); a `@MainActor`-only API like `removeAllScriptMessageHandlers()`
has no clean deinit home, which is the other reason it's gone.

The console ring buffer is private to `BrowserCoordinator`; a `#if DEBUG`
`debugAppendConsole` seam (mirroring `debugLastMediaSuspended`) makes the
cap/threshold/drain behaviour unit-testable without a live page.
