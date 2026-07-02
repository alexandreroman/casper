import CasperCore
import Foundation
import Observation

/// The single owner of runtime UI state and the bridge from the non-observable
/// core types to SwiftUI. Membership changes (add/remove folder) persist
/// synchronously; high-frequency agent-state changes (Task 4) debounce.
@MainActor
@Observable
final class AppModel {
    private(set) var workspaces: [Workspace]
    var selectedWorkspaceID: UUID?

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private var portAllocator: PortAllocator

    init(
        sessionStore: SessionStore,
        portAllocator: PortAllocator = PortAllocator(),
        session: Session = Session()
    ) {
        self.sessionStore = sessionStore
        self.portAllocator = portAllocator
        self.workspaces = session.workspaces
        self.selectedWorkspaceID = session.workspaces.first?.id
        // Reserve restored port blocks so a later allocate() never collides.
        for ws in session.workspaces { self.portAllocator.reserve(ws.portBase) }
    }

    var isEmpty: Bool { workspaces.isEmpty }

    func addWorkspace(folderURL: URL, probe: (URL) -> WorkspaceFactory.RepoInfo?) {
        let portBase = (try? portAllocator.allocate()) ?? portAllocator.rangeStart
        let ws = WorkspaceFactory.makeWorkspace(
            folderURL: folderURL, probe: probe, portBase: portBase)
        workspaces.append(ws)
        selectedWorkspaceID = ws.id
        persist()
    }

    func removeWorkspace(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        portAllocator.release(workspaces[index].portBase)
        workspaces.remove(at: index)
        if selectedWorkspaceID == id { selectedWorkspaceID = workspaces.first?.id }
        persist()
    }

    func persist() {
        do {
            try sessionStore.save(Session(workspaces: workspaces))
        } catch {
            CasperLog.app.error("failed to persist session: \(String(describing: error), privacy: .public)")
        }
    }
}
