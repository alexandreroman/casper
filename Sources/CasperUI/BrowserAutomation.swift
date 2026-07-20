import Foundation

/// Builds the JavaScript source strings that drive Playwright-style browser
/// automation (`click` / `type` / `key` / `content`) through
/// `WKWebView.evaluateJavaScript`.
///
/// Pure string construction, with no WebKit dependency, so the escaping logic is
/// unit-testable in isolation. Every selector and text value is embedded as a
/// JSON string literal (never naively interpolated), so quotes, backslashes and
/// `</script>`-like content can't break out of the surrounding quotes. Each
/// builder's script throws inside the page when its selector matches nothing, so
/// the outer `evaluate` call rejects with a clear message instead of silently
/// doing nothing.
enum BrowserAutomation {
    /// Click the first element matching `selector`.
    static func click(selector: String) -> String {
        """
        (function () {
          const el = document.querySelector(\(jsLiteral(selector)));
          if (el === null) { throw new Error(\(notFoundMessage(selector))); }
          el.click();
          return null;
        })();
        """
    }

    /// Focus the first element matching `selector`, set its value to `value`, and
    /// dispatch the `input` and `change` events frameworks listen for.
    static func type(selector: String, value: String) -> String {
        """
        (function () {
          const el = document.querySelector(\(jsLiteral(selector)));
          if (el === null) { throw new Error(\(notFoundMessage(selector))); }
          el.focus();
          el.value = \(jsLiteral(value));
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return null;
        })();
        """
    }

    /// Dispatch a `keydown` then a `keyup` `KeyboardEvent` for `key`. The target
    /// is the first element matching `selector` when given (throwing if none
    /// matches), otherwise the currently focused element (falling back to the
    /// document body).
    static func key(key: String, selector: String?) -> String {
        """
        (function () {
          const target = \(keyTargetExpression(selector));
          target.dispatchEvent(new KeyboardEvent("keydown", { key: \(jsLiteral(key)), bubbles: true }));
          target.dispatchEvent(new KeyboardEvent("keyup", { key: \(jsLiteral(key)), bubbles: true }));
          return null;
        })();
        """
    }

    /// Scroll the page vertically by one viewport height — down when `down` is
    /// true, up otherwise. Returns null so the outer `evaluate` resolves cleanly.
    static func scroll(down: Bool) -> String {
        """
        (function () {
          window.scrollBy(0, \(down ? "window.innerHeight" : "-window.innerHeight"));
          return null;
        })();
        """
    }

    /// Jump the page to the very bottom (`bottom` true) or the very top.
    /// Returns null so the outer `evaluate` resolves cleanly.
    static func scrollToEdge(bottom: Bool) -> String {
        """
        (function () {
          window.scrollTo(0, \(bottom ? "document.documentElement.scrollHeight" : "0"));
          return null;
        })();
        """
    }

    /// Return the `outerHTML` of the first element matching `selector`, or of the
    /// whole document when `selector` is nil.
    static func content(selector: String?) -> String {
        guard let selector else {
            return """
            (function () {
              return document.documentElement.outerHTML;
            })();
            """
        }
        return """
        (function () {
          const el = document.querySelector(\(jsLiteral(selector)));
          if (el === null) { throw new Error(\(notFoundMessage(selector))); }
          return el.outerHTML;
        })();
        """
    }

    /// Return the page's current URL (`window.location.href`).
    static func currentURL() -> String {
        """
        (function () {
          return window.location.href;
        })();
        """
    }

    // MARK: - Wait predicates

    // These return a boolean *expression* (not a full statement): the coordinator
    // wraps each in `!!(…)` before evaluating, so a truthy result means "ready".
    // Selectors are embedded as JSON string literals, like the action builders.

    /// True once `selector` matches at least one element.
    static func presenceJS(selector: String) -> String {
        "document.querySelector(\(jsLiteral(selector))) !== null"
    }

    /// True once `selector` matches an element that is actually visible: attached
    /// to the render tree (`offsetParent !== null`) and with a non-zero bounding
    /// rect. Matches the CSS spec's notion of "shown", not merely present.
    static func visibleJS(selector: String) -> String {
        """
        (function () {
          const el = document.querySelector(\(jsLiteral(selector)));
          if (el === null) { return false; }
          if (el.offsetParent === null) { return false; }
          const rect = el.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        })()
        """
    }

    /// True once `selector` matches nothing (the negation of `presenceJS`).
    static func goneJS(selector: String) -> String {
        "document.querySelector(\(jsLiteral(selector))) === null"
    }

    /// True once the document has finished loading (`readyState === "complete"`).
    static func readyStateCompleteJS() -> String {
        "document.readyState === \"complete\""
    }

    // MARK: - JS source helpers

    /// The JS expression that resolves the target element for a `key` dispatch.
    private static func keyTargetExpression(_ selector: String?) -> String {
        guard let selector else { return "document.activeElement || document.body" }
        return """
        (function () {
            const el = document.querySelector(\(jsLiteral(selector)));
            if (el === null) { throw new Error(\(notFoundMessage(selector))); }
            return el;
          })()
        """
    }

    /// The JSON-encoded "no element matches '<selector>'" error message.
    private static func notFoundMessage(_ selector: String) -> String {
        jsLiteral("no element matches '\(selector)'")
    }

    /// Encode `value` as a JSON string literal (including the surrounding quotes)
    /// so it embeds safely into JavaScript source. JSON's string grammar is a
    /// subset of JavaScript's, so the result is a valid JS string literal.
    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
