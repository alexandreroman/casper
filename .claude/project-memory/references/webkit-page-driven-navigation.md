---
name: "Page-driven navigation in WKWebView"
description: "Same-document navigations need KVO, window.open needs a UI delegate, and the offscreen-test traps behind both"
type: reference
---

# Page-driven navigation in WKWebView

## Same-document navigation fires no delegate callback

`history.pushState`/`replaceState`, hash changes (`location.hash`, in-page
anchor clicks) and same-document `history.back()`/`forward()`/`go()` reach **no
public `WKNavigationDelegate` callback at all**. A browser surface deriving its
address bar, persisted URL and back/forward state only from
`didCommit`/`didFinish` goes stale the moment a page routes client-side, even
though `pushState` did push a back-forward entry.

`WKWebView.url`, `.canGoBack` and `.canGoForward` are KVO-compliant and do
report these, and KVO for them is delivered on the main thread. On a
`@MainActor` class, observe them with
`webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { … } }`
and keep the `NSKeyValueObservation`s in a stored array. They invalidate
themselves on dealloc, so no `deinit` is needed — which also sidesteps
[[isolated-deinit-ci-sigabrt]].

Ordinary full navigations the page triggers (`location.href`, link clicks, form
submissions, meta refresh) and HTTP 3xx redirects already commit through the
delegate; KVO only makes the address bar follow them *earlier*.

**KVO fires while a navigation is still provisional** — measured: `url` and
`isLoading` both change synchronously inside `webView.load(_:)`, before
`didStartProvisionalNavigation`. So the address bar shows the pending URL while
it loads (what every browser does), and any commit hook runs on a URL that has
not committed. Casper accepts that: every later commit, finish and failure
re-syncs, so the persisted URL converges. `isLoading` is not a usable gate — it
stays true past `didCommit` until the page finishes.

## window.open / target="_blank" are dropped without a UI delegate

With no `WKUIDelegate`, WebKit **silently discards** `window.open(…)` and
`target="_blank"` navigations — the link does nothing at all, no error, no
console message. Implementing `webView(_:createWebViewWith:for:windowFeatures:)`
and loading `navigationAction.request` in the same web view (returning nil,
since no new web view is created) is how a single-pane browser adopts them.
Confirmed both ways by probe.

## Testing this offscreen (no server, no window)

A real `WKWebView` built in XCTest loads, evaluates JS and routes. Four traps:

- A load issued in the coordinator's `init` (Casper loads `about:blank`) commits
  **asynchronously**; issuing the test's own load first lets the placeholder
  land *afterwards*. Wait for `webView.url != nil` first.
- The **document** adopts the base URL a beat *after* `webView.url` commits.
  Scripting history before that fails with `SecurityError: Blocked attempt to
  use history.pushState() to change session history URL from
  about:blank`. Gate on the page's own `location.href`, not on `webView.url`.
- A script that navigates (`history.back()`, `location.href = …`) **loses its
  own reply**: `evaluateJavaScript` returns an error. Ignore the result and
  assert on the resulting state.
- A `loadHTMLString` document's back-forward entry **cannot be restored** —
  going back onto it leaves `webView.url` nil. Traverse between two pushState
  entries instead, or serve real files with `loadFileURL`.

And one XCTest trap that costs hours: when a test method throws while an
`XCTestExpectation` is still unfulfilled, XCTest reports
`InvalidTransition { phase: idle, targetPhase: failed(deinit) }` at some
unrelated `deinit` line **instead of the real error**. Catch and print the error
to see what actually happened.

`Tests/CasperUITests/BrowserURLSyncTests.swift` is the worked example.
