---
name: "Browser ATS disabled app-wide"
description: "NSAllowsArbitraryLoads=true lets the embedded WKWebView load plain-HTTP dev servers via public-qualified hostnames"
type: project
---

# Browser ATS disabled app-wide

Both packaged Info.plists (`Packaging/Info.plist` and `Packaging/Info-dev.plist`)
set `NSAppTransportSecurity › NSAllowsArbitraryLoads = true`, disabling App
Transport Security for the whole app so the embedded `WKWebView` browser
(`CasperUI/BrowserSurfaceView` + `BrowserCoordinator`) can load plain-HTTP local
dev servers.

**Why:** ATS evaluates the URL's *hostname string*, not the resolved IP. Local
dev URLs like `http://pizza.127.0.0.1.nip.io` (nip.io/sslip.io, custom
`/etc/hosts` entries) are public-*qualified* hostnames that happen to resolve to
loopback — ATS treats them as public domains and blocks the plain-HTTP load
("the App Transport Security policy requires the use of a secure connection").
`NSAllowsLocalNetworking` only exempts unqualified / `.local` / IP-literal hosts,
so it does **not** cover these; only `NSAllowsArbitraryLoads` does. Casper's
browser is a dev-server preview tool (it behaves like Safari/Chrome, which ignore
ATS anyway) and is not App-Store-distributed, so the app-wide relaxation is a
sanctioned trade-off.

**How to apply:** ATS is read from `Info.plist` at process launch, so the app
must be relaunched (not just rebuilt) after this key changes. This is a
deliberate security trade-off — revisit it on its merits if the browser's threat
model changes (e.g. it stops being a local-preview-only tool). Related:
[[browser-automation-cli]], [[browser-address-bar-select-all]].
