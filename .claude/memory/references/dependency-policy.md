---
name: dependency-policy
description: "Casper's strict dependency-minimalism stance and the only allowed external deps"
type: feedback
---

# dependency-policy

For Casper, the user requires a **native, performant macOS app** that **always
prefers built-in macOS frameworks**, with the **smallest possible binary** and
**minimum external dependencies**.

**Why:** it is a distributable product where size and native feel matter; the
user rejects heavyweight stacks (e.g. no Chromium/CEF — the browser is WKWebView).

**How to apply:** only **three** external dependencies are sanctioned —
**GhosttyKit** (libghostty terminal engine), **swift-argument-parser** (CLI),
and **libgit2** (Git, wrapped in an in-house `CasperGit` module; no external
`git` binary). Everything else must use system frameworks (Network.framework,
WebKit, UserNotifications, Foundation/Codable). Build **arm64-only**, release
with `-Osize` + LTO + strip. Before adding any new package, stop and justify it
against this policy. See [[project]].
