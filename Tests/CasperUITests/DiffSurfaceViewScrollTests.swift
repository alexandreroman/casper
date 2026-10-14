import AppKit
import CasperCore
import CasperTestSupport
import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import CasperUI

/// `casper diff open <file>` end to end through the real inspector panel: the
/// request lands on a model, the panel mounts `DiffSurfaceView`, and the clip view
/// has to end up on the file's band.
@MainActor
final class DiffSurfaceViewScrollTests: XCTestCase {
    /// The file the tests scroll to, sorted mid-diff so that neither end of the
    /// document clamps the scroll.
    private let targetFile = "docs/README.md"

    /// The scenario reproduced in the app: the panel starts collapsed, so the
    /// request is what mounts the diff view, and its surface is realized only
    /// after the request has been made — and handed the target before SwiftUI
    /// has given it a size.
    func testOpeningACollapsedPanelOnAFileScrollsToIt() async throws {
        let (model, workspaceID) = try makeModelWithChangedFiles()
        let host = hostInspectorPanel(model: model, workspaceID: workspaceID)
        XCTAssertEqual(model.workspace(id: workspaceID)?.inspector.collapsed, true)

        guard case .success = await model.controlOpenDiff(in: workspaceID, file: targetFile) else {
            return XCTFail("expected success")
        }
        await settle(host) { model.diffScrollTarget == nil }

        XCTAssertNil(model.diffScrollTarget, "the target must be settled")
        XCTAssertEqual(fileAtViewportTop(in: host), targetFile)
    }

    /// The same path from the other side: an expanded panel showing the Browser
    /// tab mounts no diff view either, so switching it to the Diff tab mounts a
    /// fresh one whose surface is handed the target before it is sized.
    func testOpeningAFileFromTheBrowserTabScrollsToIt() async throws {
        let (model, workspaceID) = try makeModelWithChangedFiles()
        let host = hostInspectorPanel(model: model, workspaceID: workspaceID)
        model.setInspectorTab(.browser, for: workspaceID)
        await settle(host) { firstDescendant(WKWebView.self, in: host) != nil }

        guard case .success = await model.controlOpenDiff(in: workspaceID, file: targetFile) else {
            return XCTFail("expected success")
        }
        await settle(host) { model.diffScrollTarget == nil }

        XCTAssertNil(model.diffScrollTarget, "the target must be settled")
        XCTAssertEqual(fileAtViewportTop(in: host), targetFile)
    }

    /// The target is one-shot end to end: collapsing unmounts the diff view, and
    /// the next expand opens it at the top rather than back on the file.
    func testReopeningThePanelAfterTheScrollOpensItAtTheTop() async throws {
        let (model, workspaceID) = try makeModelWithChangedFiles()
        let host = hostInspectorPanel(model: model, workspaceID: workspaceID)
        guard case .success = await model.controlOpenDiff(in: workspaceID, file: targetFile) else {
            return XCTFail("expected success")
        }
        await settle(host) { self.fileAtViewportTop(in: host) == self.targetFile }

        XCTAssertTrue(model.controlCloseDiff(in: workspaceID))
        await settle(host) { firstDescendant(DiffTextView.self, in: host) == nil }
        model.setInspectorTab(.diff, for: workspaceID)
        await settle(host) { self.fileAtViewportTop(in: host) != nil }

        XCTAssertEqual(fileAtViewportTop(in: host), "a00.txt")
    }

    /// The path that already worked: the surface is up and sized before the
    /// request arrives. Pins that the harness can see a scroll at all.
    func testOpeningAnExpandedPanelOnAFileScrollsToIt() async throws {
        let (model, workspaceID) = try makeModelWithChangedFiles()
        let host = hostInspectorPanel(model: model, workspaceID: workspaceID)
        model.setInspectorTab(.diff, for: workspaceID)
        await settle(host) { self.fileAtViewportTop(in: host) != nil }

        guard case .success = await model.controlOpenDiff(in: workspaceID, file: targetFile) else {
            return XCTFail("expected success")
        }
        await settle(host) { model.diffScrollTarget == nil }

        XCTAssertNil(model.diffScrollTarget, "the target must be settled")
        XCTAssertEqual(fileAtViewportTop(in: host), targetFile)
    }

    // MARK: - Fixture

    /// A Git workspace whose working tree changes many files on either side of
    /// `targetFile`, each by enough lines that the diff is many viewports tall.
    /// The inspector starts collapsed, `InspectorState`'s default.
    private func makeModelWithChangedFiles() throws -> (AppModel, UUID) {
        let repoPath = makeTemporaryDirectory(prefix: "casper-diff-scroll").path
        try FileManager.default.createDirectory(
            atPath: repoPath + "/docs", withIntermediateDirectories: true)
        let paths = (0..<20).map { String(format: "a%02d.txt", $0) } + [targetFile]
            + (0..<20).map { String(format: "z%02d.txt", $0) }
        let committed = Dictionary(uniqueKeysWithValues: paths.map { ($0, "first line\n") })
        try GitFixture.repository(at: repoPath, files: committed)
        let addedLines = (1...30).map { "added line \($0)\n" }.joined()
        for path in paths {
            try Data(("first line\n" + addedLines).utf8)
                .write(to: URL(fileURLWithPath: repoPath).appendingPathComponent(path))
        }

        let workspace = Workspace(
            name: "main", worktreePath: repoPath, branch: "",
            portBase: 41000, layout: .leaf(Surface.terminal(cwd: repoPath)))
        let space = Space(name: "main", folderPath: repoPath, isGitRepo: true, workspaces: [workspace])
        return (makeModel(spaces: [space], selecting: workspace.id), workspace.id)
    }

    /// The production `InspectorPanel`, re-rendered from the model the way
    /// `WorkspaceDetailView` re-renders it, in an off-screen window that is never
    /// ordered in (see the offscreen-host-windows-unordered note).
    private func hostInspectorPanel(model: AppModel, workspaceID: UUID) -> NSView {
        let host = NSHostingView(rootView: InspectorPanelHost(model: model, workspaceID: workspaceID))
        let window = NSWindow.offscreenHost(size: NSSize(width: 780, height: 600))
        window.contentView = host
        addTeardownBlock { @MainActor in window.close() }
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Lets the main run loop turn — the diff is computed off the main actor and
    /// the view reacts across several turns — laying the host out on each one,
    /// as the display cycle does in the app, until `condition` holds.
    ///
    /// Keeps turning a little after `condition` holds, so that a scroll the view
    /// reports as landed but that a later layout pass undoes is caught too.
    private func settle(
        _ host: NSView, timeout: TimeInterval = 10, until condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        await waitUntil(
            timeout: timeout,
            {
                host.layoutSubtreeIfNeeded()
                return condition()
            },
            file: file, line: line)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The id of the file whose band holds the viewport's top edge, read off the
    /// surface's own text view; nil while no surface shows a document.
    ///
    /// Answers nil rather than failing, so `settle` can poll it.
    private func fileAtViewportTop(in host: NSView) -> String? {
        guard let textView = firstDescendant(DiffTextView.self, in: host),
              let document = textView.document,
              let layoutManager = textView.textLayoutManager,
              let clipView = textView.enclosingScrollView?.contentView
        else { return nil }
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)
        let visibleTop = clipView.bounds.origin.y - textView.textContainerOrigin.y
        guard let fileIndex = geometry.fileIndex(atY: visibleTop) else { return nil }
        return document.files[fileIndex].id
    }
}

/// Reads the workspace from the model on every update, so a model mutation —
/// expanding the panel — re-renders the panel with the new value.
private struct InspectorPanelHost: View {
    let model: AppModel
    let workspaceID: UUID

    var body: some View {
        if let workspace = model.workspace(id: workspaceID) {
            InspectorPanel(model: model, workspace: workspace)
        }
    }
}
