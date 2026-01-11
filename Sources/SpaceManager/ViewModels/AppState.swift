import Foundation
import SwiftUI
import Combine

/// Central state management for the application
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared

    // Current selection
    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    // Agent sessions for current workspace
    @Published var agentSessions: [AgentSession] = []
    @Published var selectedAgentSession: AgentSession?

    // UI state
    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false
    @Published var showModelConfigEditor = false
    @Published var showSettingsSheet = false
    @Published var isSplitView = false
    @Published var editingModelConfig: ModelConfig?
    @Published var agentFocusMode: AgentFocusMode = {
        if let rawValue = UserDefaults.standard.string(forKey: "agentFocusMode"),
           let mode = AgentFocusMode(rawValue: rawValue) {
            return mode
        }
        return .click
    }() {
        didSet {
            UserDefaults.standard.set(agentFocusMode.rawValue, forKey: "agentFocusMode")
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var agentCounter = 1

    init() {
        storage.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .agentSelectionRequested)
            .compactMap { $0.userInfo?["id"] as? UUID }
            .sink { [weak self] sessionId in
                self?.selectAgentSession(id: sessionId)
            }
            .store(in: &cancellables)

        // Auto-select first workspace if available
        if let first = storage.workspaces.first {
            selectedWorkspace = first
            selectedProject = first.projects.first
            addAgentSession()
        }
    }

    // MARK: - Workspace Management

    func createWorkspace(rootPath: String, customName: String? = nil) {
        let workspace = Workspace(rootPath: rootPath, customName: customName)
        storage.addWorkspace(workspace)
        selectedWorkspace = workspace
        selectedProject = workspace.projects.first
        // Clean up all existing sessions
        for session in agentSessions {
            session.cleanup()
        }
        agentSessions.removeAll()
        agentCounter = 1
        addAgentSession()
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
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = storage.workspaces.first
            // Clean up all existing sessions
            for session in agentSessions {
                session.cleanup()
            }
            agentSessions.removeAll()
            if selectedWorkspace != nil {
                addAgentSession()
            }
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        selectedProject = workspace.projects.first
        // Clean up all existing sessions
        for session in agentSessions {
            session.cleanup()
        }
        agentSessions.removeAll()
        agentCounter = 1
        addAgentSession()
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard var workspace = selectedWorkspace else { return }
        let project = Project(path: path)
        workspace.addProject(project)
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
        selectedProject = project
        updateAgentWorkingDirectory()
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
        updateAgentWorkingDirectory()
    }

    private func updateAgentWorkingDirectory() {
        guard let project = selectedProject else { return }
        for session in agentSessions {
            session.workingDirectory = project.path
        }
    }

    // MARK: - Agent Session Management

    func addAgentSession() {
        let workingDir = selectedProject?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let session = AgentSession(
            name: "Agent \(agentCounter)",
            workingDirectory: workingDir
        )
        agentCounter += 1
        agentSessions.append(session)
        selectedAgentSession = session
    }

    func removeAgentSession(_ session: AgentSession) {
        // Clean up the terminal first
        session.cleanup()

        agentSessions.removeAll { $0.id == session.id }
        if selectedAgentSession?.id == session.id {
            selectedAgentSession = agentSessions.last
            if let selected = selectedAgentSession, selected.hasLaunchedCommand {
                selected.focusTerminal()
            }
        }
    }

    func selectAgentSession(_ session: AgentSession) {
        guard selectedAgentSession?.id != session.id else {
            if session.hasLaunchedCommand {
                session.focusTerminal()
            }
            return
        }
        selectedAgentSession = session
        if session.hasLaunchedCommand {
            session.focusTerminal()
        }
    }

    func selectAgentSession(id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }) else { return }
        selectAgentSession(session)
    }

    func selectNextAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        let nextIndex = (index + 1) % agentSessions.count
        selectAgentSession(agentSessions[nextIndex])
    }

    func selectPreviousAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        let prevIndex = (index - 1 + agentSessions.count) % agentSessions.count
        selectAgentSession(agentSessions[prevIndex])
    }
}

enum AgentFocusMode: String, CaseIterable, Identifiable {
    case click
    case hover

    var id: String { rawValue }
    var title: String {
        switch self {
        case .click:
            return "Click to focus"
        case .hover:
            return "Hover to focus"
        }
    }
}
