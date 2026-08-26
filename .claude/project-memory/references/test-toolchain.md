---
name: "Test toolchain"
description: "How to build/test Casper locally — XCTest needs the Xcode toolchain, and the suite compiles in debug only"
type: reference
---

# Test toolchain

Casper's tests use **XCTest** and require the **full Xcode toolchain** — the
Command Line Tools' `swift` cannot link XCTest (symptom: `XCTestCase` resolves
but `XCTAssert*` are "cannot find in scope"; Swift Testing's `import Testing` is
also absent under CLT).

**How to run tests locally:** with the full Xcode toolchain selected
(`sudo xcode-select -s /Applications/Xcode.app`), plain `swift test` and
`make test` work. If the toolchain is ever mixed, `.build` gets corrupted — fix
with `rm -rf .build`. Without a global switch, use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.

**Gotcha:** `import XCTest` does not re-export Foundation on current SDKs —
every XCTest file using `URL`/`Data`/`FileManager`/`UUID`/`JSONEncoder` must
`import Foundation` explicitly.

**Debug-only suite:** the tests compile in the **debug configuration only**.
`swift test -c release` fails at compile time, because the suite reaches
`#if DEBUG` seams in the production modules — `LoginShellPath`'s `.shellProbe`
and `.processSearchPath`, `MainThreadHangWatchdog`, the browser suites' debug
hooks, and
`AppModel`'s `debug*` accessors — none of which exist in a release build.
`make test` and plain `swift test` are the supported way to run them. A
`#if DEBUG` wrapper around a test that reaches such a symbol is therefore
optional: a few files carry one, most do not, and neither shape breaks the
suite. See [[debug-channel-gating]] for what that gating protects.

Tests also run in **GitHub Actions CI** on a `macos-15` / `macos-26` matrix —
`.github/workflows/ci.yml`. See [[swift-toolchain-floor]] for the required Xcode
version pin.
