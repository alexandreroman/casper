---
name: test-toolchain
description: "How to build/test Casper locally — XCTest needs the Xcode toolchain, not Command Line Tools"
type: reference
---

# test-toolchain

Casper's tests use **XCTest** and require the **full Xcode toolchain** — the
Command Line Tools' `swift` cannot link XCTest (symptom: `XCTestCase` resolves
but `XCTAssert*` are "cannot find in scope"; Swift Testing's `import Testing`
is also absent under CLT).

**How to run tests locally:** with the full Xcode toolchain selected
(`sudo xcode-select -s /Applications/Xcode.app`), plain `swift test` and
`make test` work. If the toolchain is ever mixed, `.build` gets corrupted — fix
with `rm -rf .build`. Without a global switch, use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.

**Gotcha:** recent SDKs no longer re-export Foundation through `import XCTest` —
every XCTest file using `URL`/`Data`/`FileManager`/`UUID`/`JSONEncoder` must
`import Foundation` explicitly.

Tests also run in **GitHub Actions CI** on `macos-14` (Xcode present) —
`.github/workflows/ci.yml`.
