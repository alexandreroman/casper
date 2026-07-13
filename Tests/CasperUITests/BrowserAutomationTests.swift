import XCTest
@testable import CasperUI

/// Unit tests for the pure JS builders: escaping (quotes, backslashes,
/// `</script>`), the emitted call shape, and the no-match-throws branch.
final class BrowserAutomationTests: XCTestCase {
    func testClickEmitsClickAndThrowBranch() {
        let js = BrowserAutomation.click(selector: "#go")
        XCTAssertTrue(js.contains("document.querySelector(\"#go\")"))
        XCTAssertTrue(js.contains(".click()"))
        XCTAssertTrue(js.contains("throw new Error("))
        XCTAssertTrue(js.contains("no element matches '#go'"))
    }

    func testTypeEmitsValueAndInputChangeEvents() {
        let js = BrowserAutomation.type(selector: "#name", value: "Ada")
        XCTAssertTrue(js.contains("document.querySelector(\"#name\")"))
        XCTAssertTrue(js.contains("el.focus()"))
        XCTAssertTrue(js.contains("el.value = \"Ada\""))
        XCTAssertTrue(js.contains("new Event(\"input\", { bubbles: true })"))
        XCTAssertTrue(js.contains("new Event(\"change\", { bubbles: true })"))
        XCTAssertTrue(js.contains("throw new Error("))
    }

    func testKeyWithSelectorResolvesTargetAndThrows() {
        let js = BrowserAutomation.key(key: "Enter", selector: "#field")
        XCTAssertTrue(js.contains("document.querySelector(\"#field\")"))
        XCTAssertTrue(js.contains("new KeyboardEvent(\"keydown\", { key: \"Enter\", bubbles: true })"))
        XCTAssertTrue(js.contains("new KeyboardEvent(\"keyup\", { key: \"Enter\", bubbles: true })"))
        XCTAssertTrue(js.contains("throw new Error("))
    }

    func testKeyWithoutSelectorTargetsActiveElement() {
        let js = BrowserAutomation.key(key: "Escape", selector: nil)
        XCTAssertTrue(js.contains("document.activeElement || document.body"))
        XCTAssertFalse(js.contains("querySelector"))
        XCTAssertTrue(js.contains("new KeyboardEvent(\"keydown\", { key: \"Escape\", bubbles: true })"))
    }

    func testContentWithoutSelectorReturnsDocumentHTML() {
        let js = BrowserAutomation.content(selector: nil)
        XCTAssertTrue(js.contains("document.documentElement.outerHTML"))
        XCTAssertFalse(js.contains("querySelector"))
    }

    func testContentWithSelectorReturnsElementHTMLAndThrows() {
        let js = BrowserAutomation.content(selector: "main")
        XCTAssertTrue(js.contains("document.querySelector(\"main\")"))
        XCTAssertTrue(js.contains("el.outerHTML"))
        XCTAssertTrue(js.contains("throw new Error("))
    }

    // MARK: - Escaping

    func testSelectorWithDoubleQuoteIsEscaped() {
        let js = BrowserAutomation.click(selector: "a[title=\"x\"]")
        // The double quote is escaped, so the literal never breaks out early.
        XCTAssertTrue(js.contains("document.querySelector(\"a[title=\\\"x\\\"]\")"))
        XCTAssertFalse(js.contains("querySelector(\"a[title=\"x\"]\")"))
    }

    func testSelectorWithBackslashIsEscaped() {
        let js = BrowserAutomation.click(selector: "a\\b")
        XCTAssertTrue(js.contains("document.querySelector(\"a\\\\b\")"))
    }

    func testTextWithScriptCloseTagStaysWithinStringLiteral() {
        let js = BrowserAutomation.type(selector: "#c", value: "</script><b>")
        // Embedded as a JSON literal: the forward slash is escaped (`<\/script>`),
        // so it can never close an enclosing script context, and it stays a single
        // valid string argument with the throw branch intact.
        XCTAssertTrue(js.contains("el.value = \"<\\/script><b>\""))
        XCTAssertFalse(js.contains("</script>"))
        XCTAssertTrue(js.contains("throw new Error("))
    }

    func testSelectorWithApostropheEscapesInErrorMessage() {
        let js = BrowserAutomation.click(selector: "a[href='x']")
        // The apostrophe is inside a JSON double-quoted literal, so it needs no
        // escaping there, but the whole message stays a single valid string.
        XCTAssertTrue(js.contains("no element matches 'a[href='x']'"))
        XCTAssertTrue(js.contains("document.querySelector(\"a[href='x']\")"))
    }
}
