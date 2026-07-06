/// Resolves a `--workspace` selector (a workspace id string or a workspace name)
/// against the running app's workspaces. Id match wins over name match.
public enum ControlTargeting {
    public static func match(selector: String, candidates: [ControlWorkspaceInfo]) -> String? {
        if let byID = candidates.first(where: { $0.id == selector }) { return byID.id }
        return candidates.first(where: { $0.name == selector })?.id
    }
}
