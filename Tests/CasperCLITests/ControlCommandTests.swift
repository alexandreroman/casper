import XCTest
import CasperCore
@testable import CasperCLI

final class ControlCommandTests: XCTestCase {
    func testStatusSetBuildsCommand() throws {
        let set = try StatusCommand.Set.parse(["blocked", "--workspace", "feature"])
        XCTAssertEqual(set.state, .blocked)
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .statusSet)
        XCTAssertEqual(command.state, "blocked")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testStatusSetRejectsBadState() {
        // The typed `AgentState` argument makes ArgumentParser reject an unknown
        // value at parse time (exit 64), before `makeCommand()` ever runs.
        XCTAssertThrowsError(try StatusCommand.Set.parse(["bogus", "--workspace", "feature"]))
    }

    func testProgressSetBuildsCommand() throws {
        let set = try ProgressCommand.Set.parse(
            ["--total", "5", "--current", "3", "--label", "wire", "--workspace", "feature"])
        let command = try set.makeCommand()
        XCTAssertEqual(command.verb, .progressSet)
        XCTAssertEqual(command.total, 5)
        XCTAssertEqual(command.current, 3)
        XCTAssertEqual(command.label, "wire")
    }

    func testProgressSetRejectsOutOfRange() throws {
        let set = try ProgressCommand.Set.parse(
            ["--total", "2", "--current", "5", "--label", "x", "--workspace", "feature"])
        XCTAssertThrowsError(try set.makeCommand())
    }

    func testProgressClearBuildsCommand() throws {
        let clear = try ProgressCommand.Clear.parse(["--workspace", "feature"])
        let command = try clear.makeCommand()
        XCTAssertEqual(command.verb, .progressClear)
    }

    func testNotifyBuildsCommand() throws {
        let notify = try NotifyCommand.parse(["--message", "look here", "--workspace", "feature"])
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertEqual(command.message, "look here")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testNotifyWithoutMessage() throws {
        let notify = try NotifyCommand.parse(["--workspace", "feature"])
        let command = try notify.makeCommand()
        XCTAssertEqual(command.verb, .notify)
        XCTAssertNil(command.message)
    }

    func testTerminalNewBuildsCommand() throws {
        let new = try TerminalCommand.New.parse(
            ["--workspace", "feature", "--command", "npm test", "--working-dir", "/some/dir"])
        XCTAssertEqual(new.workingDir, "/some/dir")
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .terminalNew)
        XCTAssertEqual(command.workspace, "feature")
        XCTAssertEqual(command.command, "npm test")
        XCTAssertEqual(command.cwd, "/some/dir")
    }

    func testTerminalNewTreatsEmptyCommandAsNil() throws {
        let new = try TerminalCommand.New.parse(["--workspace", "feature", "--command", ""])
        XCTAssertNil(try new.makeCommand().command)
    }

    func testTerminalListBuildsCommand() throws {
        let list = try TerminalCommand.List.parse(["--workspace", "feature"])
        let command = try list.makeCommand()
        XCTAssertEqual(command.verb, .terminalList)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testTerminalCloseBuildsCommand() throws {
        let uuid = UUID().uuidString
        let close = try TerminalCommand.Close.parse([uuid, "--workspace", "f"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .terminalClose)
        XCTAssertEqual(command.target, uuid)
        XCTAssertEqual(command.workspace, "f")
    }

    func testBrowserOpenBuildsCommand() throws {
        let open = try BrowserCommand.Open.parse(["https://example.com", "--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .browserOpen)
        XCTAssertEqual(command.url, "https://example.com")
    }

    func testBrowserOpenRejectsEmptyURL() throws {
        let open = try BrowserCommand.Open.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try open.makeCommand())
    }

    func testBrowserOpenRejectsInvalidURL() throws {
        let schemeless = try BrowserCommand.Open.parse(["not-a-url", "--workspace", "feature"])
        XCTAssertThrowsError(try schemeless.makeCommand())

        // A dotted host without a scheme parses as a relative URL, not an absolute web URL.
        let dottedHost = try BrowserCommand.Open.parse(["example.com", "--workspace", "feature"])
        XCTAssertThrowsError(try dottedHost.makeCommand())
    }

    func testBrowserLoadBuildsCommand() throws {
        let load = try BrowserCommand.Load.parse(["https://example.com", "--workspace", "feature"])
        let command = try load.makeCommand()
        XCTAssertEqual(command.verb, .browserLoad)
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testBrowserLoadRejectsEmptyURL() throws {
        let load = try BrowserCommand.Load.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try load.makeCommand())
    }

    func testBrowserLoadRejectsRelativeURL() throws {
        // A dotted host without a scheme parses as a relative URL, not an absolute web URL.
        let load = try BrowserCommand.Load.parse(["example.com", "--workspace", "feature"])
        XCTAssertThrowsError(try load.makeCommand())
    }

    func testBrowserCloseBuildsCommand() throws {
        let close = try BrowserCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .browserClose)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testBrowserScreenshotDefaultsToTempPath() throws {
        let shot = try BrowserCommand.Screenshot.parse(["--workspace", "feature"])
        let command = try shot.makeCommand()
        XCTAssertEqual(command.verb, .browserScreenshot)
        XCTAssertEqual(command.workspace, "feature")
        XCTAssertTrue(command.path?.hasSuffix(".png") ?? false)
    }

    func testBrowserScreenshotCarriesOutPath() throws {
        let shot = try BrowserCommand.Screenshot.parse(["--out", "/tmp/x.png", "--workspace", "feature"])
        XCTAssertEqual(try shot.makeCommand().path, "/tmp/x.png")
    }

    func testBrowserScreenshotCarriesWidthAndHeight() throws {
        let shot = try BrowserCommand.Screenshot.parse(
            ["--width", "800", "--height", "600", "--workspace", "feature"])
        let command = try shot.makeCommand()
        XCTAssertEqual(command.width, 800)
        XCTAssertEqual(command.height, 600)
    }

    func testBrowserScreenshotCarriesURLWithDimensions() throws {
        let shot = try BrowserCommand.Screenshot.parse(
            ["--url", "https://example.com", "--width", "375", "--height", "800", "--workspace", "feature"])
        let command = try shot.makeCommand()
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertEqual(command.width, 375)
        XCTAssertEqual(command.height, 800)
    }

    func testBrowserScreenshotWithoutFlagsCarriesNoOverrides() throws {
        let shot = try BrowserCommand.Screenshot.parse(["--workspace", "feature"])
        let command = try shot.makeCommand()
        XCTAssertNil(command.url)
        XCTAssertNil(command.width)
        XCTAssertNil(command.height)
    }

    func testBrowserScreenshotRejectsNonPositiveWidth() throws {
        let shot = try BrowserCommand.Screenshot.parse(["--width", "0", "--workspace", "feature"])
        XCTAssertThrowsError(try shot.makeCommand())
    }

    func testBrowserScreenshotRejectsNegativeHeight() throws {
        // Attached `--height=-1` form so ArgumentParser doesn't read the leading `-`
        // as a new flag; the non-positive value is then rejected by `makeCommand`.
        let shot = try BrowserCommand.Screenshot.parse(["--height=-1", "--workspace", "feature"])
        XCTAssertThrowsError(try shot.makeCommand())
    }

    func testBrowserScreenshotRejectsRelativeURL() throws {
        // A dotted host without a scheme parses as a relative URL, not an absolute web URL.
        let shot = try BrowserCommand.Screenshot.parse(["--url", "example.com", "--workspace", "feature"])
        XCTAssertThrowsError(try shot.makeCommand())
    }

    func testBrowserEvalBuildsCommand() throws {
        let eval = try BrowserCommand.Eval.parse(["document.title", "--workspace", "feature"])
        let command = try eval.makeCommand()
        XCTAssertEqual(command.verb, .browserEval)
        XCTAssertEqual(command.script, "document.title")
    }

    func testBrowserEvalRejectsEmptyScript() throws {
        let eval = try BrowserCommand.Eval.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try eval.makeCommand())
    }

    func testBrowserEvalResultLineEmbedsRawJSON() {
        let line = BrowserCommand.Eval.resultLine(value: "{\"a\":1}", workspace: "w")
        XCTAssertEqual(line, "{\"result\":{\"a\":1},\"workspace\":\"w\"}")
    }

    func testBrowserEvalRawUnwrapsStringButNotOtherTokens() {
        // `eval --raw` unwraps a JSON string to its bare contents for shell piping,
        // but leaves numbers, booleans, null, and containers as-is.
        XCTAssertEqual(unwrappedRawValue("\"My Title\""), "My Title")
        XCTAssertEqual(unwrappedRawValue("42"), "42")
        XCTAssertEqual(unwrappedRawValue("true"), "true")
        XCTAssertEqual(unwrappedRawValue("null"), "null")
        XCTAssertEqual(unwrappedRawValue("{\"a\":1}"), "{\"a\":1}")
    }

    func testBrowserContentBuildsCommand() throws {
        let content = try BrowserCommand.Content.parse(["--selector", "main", "--workspace", "feature"])
        let command = try content.makeCommand()
        XCTAssertEqual(command.verb, .browserContent)
        XCTAssertEqual(command.selector, "main")
    }

    func testBrowserContentRejectsEmptySelector() throws {
        let content = try BrowserCommand.Content.parse(["--selector", "", "--workspace", "feature"])
        XCTAssertThrowsError(try content.makeCommand())
    }

    func testBrowserClickBuildsCommand() throws {
        let click = try BrowserCommand.Click.parse(["#go", "--workspace", "feature"])
        let command = try click.makeCommand()
        XCTAssertEqual(command.verb, .browserClick)
        XCTAssertEqual(command.selector, "#go")
    }

    func testBrowserClickRejectsEmptySelector() throws {
        let click = try BrowserCommand.Click.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try click.makeCommand())
    }

    func testBrowserTypeBuildsCommand() throws {
        let type = try BrowserCommand.TypeText.parse(["#name", "Ada", "--workspace", "feature"])
        let command = try type.makeCommand()
        XCTAssertEqual(command.verb, .browserType)
        XCTAssertEqual(command.selector, "#name")
        XCTAssertEqual(command.value, "Ada")
    }

    func testBrowserTypeRejectsEmptySelector() throws {
        let type = try BrowserCommand.TypeText.parse(["", "Ada", "--workspace", "feature"])
        XCTAssertThrowsError(try type.makeCommand())
    }

    func testBrowserTypeRejectsEmptyText() throws {
        let type = try BrowserCommand.TypeText.parse(["#name", "", "--workspace", "feature"])
        XCTAssertThrowsError(try type.makeCommand())
    }

    func testBrowserKeyBuildsCommand() throws {
        let key = try BrowserCommand.Key.parse(["Enter", "--selector", "#field", "--workspace", "feature"])
        let command = try key.makeCommand()
        XCTAssertEqual(command.verb, .browserKey)
        XCTAssertEqual(command.key, "Enter")
        XCTAssertEqual(command.selector, "#field")
    }

    func testBrowserKeyWithoutSelectorIsNil() throws {
        let key = try BrowserCommand.Key.parse(["Escape", "--workspace", "feature"])
        let command = try key.makeCommand()
        XCTAssertEqual(command.key, "Escape")
        XCTAssertNil(command.selector)
    }

    func testBrowserKeyRejectsEmptyKey() throws {
        let key = try BrowserCommand.Key.parse(["", "--workspace", "feature"])
        XCTAssertThrowsError(try key.makeCommand())
    }

    // MARK: - browser console / wait / reload

    func testBrowserConsoleBuildsCommand() throws {
        let console = try BrowserCommand.Console.parse(["--level", "warn", "--clear", "--workspace", "feature"])
        let command = try console.makeCommand()
        XCTAssertEqual(command.verb, .browserConsole)
        XCTAssertEqual(command.level, "warn")
        XCTAssertEqual(command.clear, true)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testBrowserConsoleWithoutLevelOrClear() throws {
        let console = try BrowserCommand.Console.parse(["--workspace", "feature"])
        let command = try console.makeCommand()
        XCTAssertNil(command.level)
        XCTAssertNil(command.clear)
    }

    func testBrowserConsoleRejectsInvalidLevel() throws {
        let console = try BrowserCommand.Console.parse(["--level", "bogus", "--workspace", "feature"])
        XCTAssertThrowsError(try console.makeCommand())
    }

    func testBrowserConsoleLineEmbedsRawJSON() {
        let line = BrowserCommand.Console.consoleLine(entries: "[{\"level\":\"log\"}]", workspace: "w")
        XCTAssertEqual(line, "{\"console\":[{\"level\":\"log\"}],\"workspace\":\"w\"}")
    }

    func testBrowserWaitWithSelectorBuildsCommand() throws {
        let wait = try BrowserCommand.Wait.parse(["#main", "--visible", "--timeout", "1000", "--workspace", "f"])
        let command = try wait.makeCommand()
        XCTAssertEqual(command.verb, .browserWait)
        XCTAssertEqual(command.selector, "#main")
        XCTAssertEqual(command.visible, true)
        XCTAssertEqual(command.waitTimeout, 1000)
        XCTAssertNil(command.predicate)
    }

    func testBrowserWaitWithJSBuildsCommand() throws {
        let wait = try BrowserCommand.Wait.parse(["--js", "window.ready === true", "--workspace", "f"])
        let command = try wait.makeCommand()
        XCTAssertEqual(command.predicate, "window.ready === true")
        XCTAssertNil(command.selector)
        XCTAssertEqual(command.waitTimeout, 5000)   // default
    }

    func testBrowserWaitRejectsBothSelectorAndJS() throws {
        let wait = try BrowserCommand.Wait.parse(["#main", "--js", "true", "--workspace", "f"])
        XCTAssertThrowsError(try wait.makeCommand())
    }

    func testBrowserWaitRejectsNeitherSelectorNorJS() throws {
        let wait = try BrowserCommand.Wait.parse(["--workspace", "f"])
        XCTAssertThrowsError(try wait.makeCommand())
    }

    func testBrowserWaitRejectsVisibleAndGone() throws {
        let wait = try BrowserCommand.Wait.parse(["#m", "--visible", "--gone", "--workspace", "f"])
        XCTAssertThrowsError(try wait.makeCommand())
    }

    func testBrowserWaitRejectsVisibleWithJS() throws {
        let wait = try BrowserCommand.Wait.parse(["--js", "true", "--visible", "--workspace", "f"])
        XCTAssertThrowsError(try wait.makeCommand())
    }

    func testBrowserWaitRejectsNonPositiveTimeout() throws {
        let wait = try BrowserCommand.Wait.parse(["#m", "--timeout", "0", "--workspace", "f"])
        XCTAssertThrowsError(try wait.makeCommand())
    }

    func testBrowserReloadBuildsCommand() throws {
        let reload = try BrowserCommand.Reload.parse(["--workspace", "f"])
        let command = try reload.makeCommand()
        XCTAssertEqual(command.verb, .browserReload)
        XCTAssertNil(command.waitReady)
    }

    func testBrowserReloadWithWaitBuildsCommand() throws {
        let reload = try BrowserCommand.Reload.parse(["--wait", "--workspace", "f"])
        let command = try reload.makeCommand()
        XCTAssertEqual(command.waitReady, true)
    }

    func testDiffOpenBuildsCommand() throws {
        let open = try DiffCommand.Open.parse(["--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .diffOpen)
        XCTAssertNil(command.target)
    }

    func testDiffOpenCarriesFileArgument() throws {
        let open = try DiffCommand.Open.parse(["Sources/Foo.swift", "--workspace", "feature"])
        let command = try open.makeCommand()
        XCTAssertEqual(command.verb, .diffOpen)
        XCTAssertEqual(command.target, "Sources/Foo.swift")
    }

    func testDiffCloseBuildsCommand() throws {
        let close = try DiffCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .diffClose)
        XCTAssertEqual(command.workspace, "feature")
    }

    func testWorkspaceNewBuildsCommand() throws {
        // The branch is now the required positional subject (not `--branch`).
        let new = try WorkspaceCommand.New.parse(["feature-x", "--base", "main", "--workspace", "primary"])
        XCTAssertEqual(new.branch, "feature-x")
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.branch, "feature-x")
        XCTAssertEqual(command.base, "main")
        XCTAssertNil(command.command)
    }

    func testWorkspaceNewCarriesCommand() throws {
        let new = try WorkspaceCommand.New.parse(["feature-x", "--command", "npm test", "--workspace", "primary"])
        let command = try new.makeCommand()
        XCTAssertEqual(command.verb, .workspaceNew)
        XCTAssertEqual(command.command, "npm test")
    }

    func testWorkspaceNewTreatsEmptyCommandAsNil() throws {
        let new = try WorkspaceCommand.New.parse(["feature-x", "--command", "", "--workspace", "primary"])
        let command = try new.makeCommand()
        XCTAssertNil(command.command)
    }

    func testWorkspaceNewRequiresBranch() {
        // The branch is a required positional; ArgumentParser rejects its absence at parse time.
        XCTAssertThrowsError(try WorkspaceCommand.New.parse(["--workspace", "primary"]))
    }

    func testWorkspaceDeleteBuildsCommand() throws {
        let delete = try WorkspaceCommand.Delete.parse(["--workspace", "f"])
        let command = try delete.makeCommand()
        XCTAssertEqual(command.verb, .workspaceDelete)
        XCTAssertEqual(command.workspace, "f")
    }

    func testWorkspaceListBuildsCommand() throws {
        let list = try WorkspaceCommand.List.parse([])
        XCTAssertEqual(list.makeCommand().verb, .workspaceList)
    }

    func testWorkspaceCurrentReadsEnv() throws {
        let current = try WorkspaceCommand.Current.parse([])
        XCTAssertEqual(current.resolve(environment: ["CASPER_WORKSPACE_ID": "abc"]), "abc")
        XCTAssertNil(current.resolve(environment: [:]))
    }

    func testNormalizedCommand() {
        // Shared by `terminal new` and `workspace new`: empty string means "no command".
        XCTAssertNil(normalizedCommand(nil))
        XCTAssertNil(normalizedCommand(""))
        XCTAssertEqual(normalizedCommand("npm test"), "npm test")
    }

    func testRunDefaultsToRunCommand() throws {
        let run = try RunCommand.parse(["--workspace", "feature"])
        let command = try run.makeCommand()
        XCTAssertEqual(command.verb, .run)
        XCTAssertEqual(command.name, "run")
        XCTAssertEqual(command.workspace, "feature")
    }

    func testRunTakesExplicitName() throws {
        let run = try RunCommand.parse(["test", "--workspace", "feature"])
        let command = try run.makeCommand()
        XCTAssertEqual(command.name, "test")
    }
}
