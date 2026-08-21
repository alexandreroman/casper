import Foundation

/// Resolves a `--workspace` selector (a workspace id string or a workspace name)
/// against the running app's workspaces. Id match wins over name match.
///
/// The id comparison is **case-insensitive**: Casper emits ids in their canonical
/// lowercase form (`UUID.casperID`), but a caller can still pass an uppercase one —
/// an old `$CASPER_WORKSPACE_ID` exported in a long-lived shell, or a copy/paste
/// from an older build. The name comparison stays exact.
public enum ControlTargeting {
    public static func match(selector: String, candidates: [ControlWorkspaceInfo]) -> String? {
        if let byID = candidates.first(where: { $0.id.caseInsensitiveCompare(selector) == .orderedSame }) {
            return byID.id
        }
        return candidates.first(where: { $0.name == selector })?.id
    }
}
