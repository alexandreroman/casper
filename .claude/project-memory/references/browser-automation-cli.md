---
name: "Browser automation CLI"
description: "casper browser screenshot/eval/content/click/type/key: design decisions + the control-socket-in-TMPDIR live-driving gotcha"
type: project
---

# Browser automation CLI

`casper browser` gains six automation verbs beyond `open`/`close`, driving the
workspace's inspector `WKWebView`: `screenshot [--out]`, `eval <js> [--raw]`,
`content [--selector] [--raw]`, `click <selector>`, `type <selector> <text>`,
`key <key> [--selector]`. They live on the **release control channel**
([[domain-cli-control-channel]]), not the DEBUG-only `casper debug` channel — so
they ship in every build.

## Design decisions (the durable "why")

- **Input is JS-synthesized, not real OS events.** `click`/`type`/`key` build a
  JS snippet (`querySelector` + `.click()` / set `.value` + dispatch
  `input`+`change` / dispatch `keydown`+`keyup`) run via `evaluateJavaScript`.
  Chosen over `NSEvent`/`CGEvent` synthesis because it is deterministic, needs
  no window focus / coordinate mapping, and works while the panel is collapsed
  or off-screen. Trade-off: it drives the DOM, not the real input stack (e.g.
  `type` sets `.value` and fires events; it does not emit per-character key
  events).
- **Screenshot uses `WKWebView.takeSnapshot`**, not ScreenCaptureKit — no
  screen-recording permission, captures the rendered web content (not the
  address-bar chrome), works off-screen. Distinct from the DEBUG terminal
  screenshot ([[debug-screenshot-screencapturekit]]) which captures the whole
  window and needs permission.
- **Off-screen support:** the verbs get-or-create the inspector browser's
  `BrowserCoordinator` themselves, so automation does not require the panel to
  be visible. `snapshot()` assigns a default 1280×800 frame **only when
  `webView.window == nil`** (a detached cached surface); it must NOT touch a
  mounted view's frame, or it races SwiftUI layout.
- **JS injection safety:** selectors/text are embedded as JSON string literals
  (`JSONSerialization`), which also escapes `/` (so `</script>` can't break the
  script context). Builders live in the pure `BrowserAutomation` module (no
  WebKit import) so they are unit-testable.
- **Output:** `eval` → `{"result":<json>,…}` (`--raw` prints the bare value,
  unwrapping a top-level JSON string); `content` → `{"content":"<html>",…}`
  (`--raw` prints raw HTML); `screenshot` → `{"screenshot":"<path>",…}`;
  action verbs → `{"workspace":…}`. A no-match selector / JS error / unwritable
  path → `{"error":…}`, non-zero exit.

## Live-driving gotcha

To exercise the control channel against a running app, the CLI dials
`$CASPER_CONTROL_SOCKET`. That path comes from `NSTemporaryDirectory()`, which
**ignores a `TMPDIR=/tmp` override** — the control socket lands in the per-user
Darwin temp dir (`$TMPDIR`, e.g. `/var/folders/.../T/casper-control-<session>.sock`),
NOT `/tmp`. (The DEBUG debug socket is hard-coded to `/tmp`, so the two live in
different directories under a named session.) A fresh `--session` starts with an
empty layout; to bootstrap a workspace non-interactively, pre-seed
`~/Library/Application Support/Casper/session-<name>.json` (a Space + Workspace
with a real `worktreePath`) before launch — `addSpace` is otherwise GUI-only
(`NSOpenPanel`).

**How to apply:** add a browser automation verb the same way as any control
verb — `ControlCommand.Verb` case + flat field(s) + `ControlServer` dispatch
(async, completion-reply like `workspaceDelete`) + `AppModel.controlBrowser*` +
`BrowserCommand` subcommand + JSON output — and put pure JS generation in
`BrowserAutomation`.
