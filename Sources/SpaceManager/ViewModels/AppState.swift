import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태. 워크스페이스 목록 자체는 WorkspaceStorage.shared(전역)가 소유한다.
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared

    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    @Published var agentSessions: [AgentSession] = []
    @Published var selectedAgentSession: AgentSession?
    private var agentSessionsByWorkspace: [UUID: [AgentSession]] = [:]
    private var selectedAgentIdByWorkspace: [UUID: UUID] = [:]

    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .agentSelectionRequested)
            .compactMap { $0.userInfo?["id"] as? UUID }
            .sink { [weak self] sessionId in self?.selectAgentSession(id: sessionId) }
            .store(in: &cancellables)

        if let first = storage.workspaces.first {
            selectWorkspace(first)
        }
    }

    // MARK: - Workspace Management

    func createWorkspace(rootPath: String, customName: String? = nil) {
        let workspace = Workspace(rootPath: rootPath, customName: customName)
        storage.addWorkspace(workspace)
        selectWorkspace(workspace)
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String?) {
        guard var ws = storage.workspace(id: workspace.id) else { return }
        ws.rename(to: newName)
        storage.updateWorkspace(ws)
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        storage.deleteWorkspace(workspace)
        if let sessions = agentSessionsByWorkspace[workspace.id] {
            for session in sessions { session.cleanup() }
        }
        agentSessionsByWorkspace[workspace.id] = nil
        selectedAgentIdByWorkspace[workspace.id] = nil
        if selectedWorkspace?.id == workspace.id {
            if let next = storage.workspaces.first {
                selectWorkspace(next)
            } else {
                selectedWorkspace = nil
                selectedProject = nil
                agentSessions = []
                selectedAgentSession = nil
            }
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
        if let current = selectedWorkspace {
            agentSessionsByWorkspace[current.id] = agentSessions
            selectedAgentIdByWorkspace[current.id] = selectedAgentSession?.id
        }
        selectedWorkspace = workspace
        selectedProject = Project(path: workspace.rootPath, name: workspace.name)
        ensureSessions(for: workspace)
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard var workspace = selectedWorkspace else { return }
        workspace.addProject(Project(path: path))
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
    }

    func removeProject(_ project: Project) {
        guard var workspace = selectedWorkspace else { return }
        workspace.removeProject(id: project.id)
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
        if selectedProject?.id == project.id {
            selectedProject = workspace.projects.first
        }
    }

    func selectProject(_ project: Project) {
        selectedProject = project
    }

    // MARK: - Terminal Sessions

    func addAgentSession() {
        guard let workspace = selectedWorkspace else { return }
        let session = AgentSession(
            name: "Terminal \(agentSessions.count + 1)",
            workingDirectory: workspace.rootPath
        )
        agentSessions.append(session)
        agentSessionsByWorkspace[workspace.id] = agentSessions
        selectAgentSession(session)
    }

    func removeAgentSession(_ session: AgentSession) {
        session.cleanup()
        agentSessions.removeAll { $0.id == session.id }
        if let workspace = selectedWorkspace {
            agentSessionsByWorkspace[workspace.id] = agentSessions
        }
        if selectedAgentSession?.id == session.id {
            selectedAgentSession = agentSessions.first
        }
    }

    func selectAgentSession(_ session: AgentSession) {
        guard selectedAgentSession?.id != session.id else {
            session.focusTerminal()
            return
        }
        selectedAgentSession = session
        if let workspace = selectedWorkspace {
            selectedAgentIdByWorkspace[workspace.id] = session.id
        }
        session.focusTerminal()
    }

    func selectAgentSession(id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }) else { return }
        selectAgentSession(session)
    }

    func moveAgentSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < agentSessions.count,
              destinationIndex >= 0, destinationIndex <= agentSessions.count else { return }
        var sessions = agentSessions
        sessions.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        agentSessions = sessions
        if let workspace = selectedWorkspace {
            agentSessionsByWorkspace[workspace.id] = sessions
        }
    }

    func selectNextAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        selectAgentSession(agentSessions[(index + 1) % agentSessions.count])
    }

    func selectPreviousAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        selectAgentSession(agentSessions[(index - 1 + agentSessions.count) % agentSessions.count])
    }

    private func ensureSessions(for workspace: Workspace) {
        agentSessions = agentSessionsByWorkspace[workspace.id] ?? []
        if agentSessions.isEmpty {
            addAgentSession()
        } else {
            let storedId = selectedAgentIdByWorkspace[workspace.id]
            selectedAgentSession = agentSessions.first(where: { $0.id == storedId }) ?? agentSessions.first
        }
    }
}
