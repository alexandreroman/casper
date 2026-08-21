import XCTest

/// Asserts that an injected id carries no uppercase character.
///
/// This is deliberately independent of `UUID.casperID`: comparing against the
/// helper alone would still pass if a call site bypassed it and emitted
/// `uuidString`, because the expectation would drift with the code under test.
func assertLowercased(_ value: String?, file: StaticString = #filePath, line: UInt = #line) {
    let value = value ?? ""
    XCTAssertFalse(value.isEmpty, "expected a non-empty id", file: file, line: line)
    XCTAssertEqual(value, value.lowercased(), "expected a lowercase id, got '\(value)'", file: file, line: line)
}
