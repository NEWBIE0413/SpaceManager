import Foundation
import SwiftUI
import Combine

/// Central state management for the application
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared
    private let planOrchestrator = PlanOrchestrator()

    // Current selection
    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    // Agent sessions for current workspace
    @Published var agentSessions: [AgentSession] = []
    @Published var selectedAgentSession: AgentSession?
    private var agentSessionsByWorkspace: [UUID: [AgentSession]] = [:]
    private var selectedAgentIdByWorkspace: [UUID: UUID] = [:]
    private var selectedAgentGroupIndexByWorkspace: [UUID: Int] = [:]
    private var selectedAgentIdsByWorkspaceAndGroup: [UUID: [Int: UUID]] = [:]
    private var selectedProjectPathByWorkspace: [UUID: String] = [:]
    private var agentCounterByWorkspace: [UUID: Int] = [:]
    private let agentGroupSize = 3

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

    init() {
        planOrchestrator.sessionsProvider = { [weak self] workspaceId in
            self?.activeSessions(for: workspaceId) ?? []
        }
        storage.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        hydrateAgentStatesFromStorage()

        NotificationCenter.default.publisher(for: .agentSelectionRequested)
            .compactMap { $0.userInfo?["id"] as? UUID }
            .sink { [weak self] sessionId in
                self?.selectAgentSession(id: sessionId)
            }
            .store(in: &cancellables)

        // Auto-select first workspace if available
        if let first = storage.workspaces.first {
            selectedWorkspace = first
            selectedProject = selectedProjectForWorkspace(first)
            selectedProjectPathByWorkspace[first.id] = selectedProject?.path
            ensureAgentSessions(for: first)
        }
        syncPlanOrchestrator()
    }

    // MARK: - Workspace Management

    func createWorkspace(rootPath: String, customName: String? = nil) {
        let workspace = Workspace(rootPath: rootPath, customName: customName)
        storage.addWorkspace(workspace)
        selectedWorkspace = workspace
        selectedProject = selectedProjectForWorkspace(workspace)
        selectedProjectPathByWorkspace[workspace.id] = selectedProject?.path
        ensureAgentSessions(for: workspace)
        persistAgentState(for: workspace)
        syncPlanOrchestrator()
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String?) {
        guard var ws = storage.workspace(id: workspace.id) else { return }
        ws.rename(to: newName)
        storage.updateWorkspace(ws)
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
        syncPlanOrchestrator()
    }

    func deleteWorkspace(_ workspace: Workspace) {
        storage.deleteWorkspace(workspace)
        cleanupAgentSessions(for: workspace.id)
        storage.removeAgentState(for: workspace.id)
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = storage.workspaces.first
            if selectedWorkspace != nil {
                if let selected = selectedWorkspace {
                    selectedProject = selectedProjectForWorkspace(selected)
                    selectedProjectPathByWorkspace[selected.id] = selectedProject?.path
                    ensureAgentSessions(for: selected)
                    persistAgentState(for: selected)
                }
            }
        }
        syncPlanOrchestrator()
    }

    func selectWorkspace(_ workspace: Workspace) {
        if let current = selectedWorkspace {
            agentSessionsByWorkspace[current.id] = agentSessions
            selectedAgentIdByWorkspace[current.id] = selectedAgentSession?.id
            if let groupIndex = selectedAgentGroupIndexByWorkspace[current.id],
               let selectedId = selectedAgentSession?.id {
                var groupSelections = selectedAgentIdsByWorkspaceAndGroup[current.id] ?? [:]
                groupSelections[groupIndex] = selectedId
                selectedAgentIdsByWorkspaceAndGroup[current.id] = groupSelections
            }
            selectedProjectPathByWorkspace[current.id] = selectedProject?.path
            persistAgentState(for: current)
        }
        selectedWorkspace = workspace
        selectedProject = selectedProjectForWorkspace(workspace)
        selectedProjectPathByWorkspace[workspace.id] = selectedProject?.path
        ensureAgentSessions(for: workspace)
        persistAgentState(for: workspace)
    }

    func setOrchestratorEnabled(_ workspace: Workspace, enabled: Bool) {
        guard var updated = storage.workspace(id: workspace.id) else { return }
        updated.orchestratorEnabled = enabled
        storage.updateWorkspace(updated)
        if selectedWorkspace?.id == updated.id {
            selectedWorkspace = updated
        }
        ensurePlanFolderExists(for: updated)
        syncPlanOrchestrator()
    }

    private func ensurePlanFolderExists(for workspace: Workspace) {
        guard workspace.orchestratorEnabled else { return }
        let planPath = (workspace.rootPath as NSString).appendingPathComponent("plan")
        if !FileManager.default.fileExists(atPath: planPath) {
            try? FileManager.default.createDirectory(atPath: planPath, withIntermediateDirectories: true)
        }
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard var workspace = selectedWorkspace else { return }
        let project = Project(path: path)
        workspace.addProject(project)
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
        selectedProject = selectedProjectForWorkspace(workspace)
        selectedProjectPathByWorkspace[workspace.id] = selectedProject?.path
        updateAgentWorkingDirectory()
        persistAgentState(for: workspace)
    }

    func removeProject(_ project: Project) {
        guard var workspace = selectedWorkspace else { return }
        workspace.removeProject(id: project.id)
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
        if selectedProject?.id == project.id {
            selectedProject = workspace.projects.first
            selectedProjectPathByWorkspace[workspace.id] = selectedProject?.path
        }
        persistAgentState(for: workspace)
    }

    func selectProject(_ project: Project) {
        selectedProject = project
        if let workspace = selectedWorkspace {
            selectedProjectPathByWorkspace[workspace.id] = project.path
        }
        updateAgentWorkingDirectory()
        if let workspace = selectedWorkspace {
            persistAgentState(for: workspace)
        }
    }

    private func updateAgentWorkingDirectory() {
        guard let project = selectedProject else { return }
        for session in agentSessions {
            session.workingDirectory = project.path
        }
        if let workspace = selectedWorkspace {
            persistAgentState(for: workspace)
        }
    }

    // MARK: - Agent Session Management

    var agentGroupCount: Int {
        agentGroups(from: agentSessions).count
    }

    var selectedAgentGroupIndex: Int {
        guard let workspace = selectedWorkspace else { return 0 }
        let maxIndex = max(0, (agentSessions.count - 1) / agentGroupSize)
        let current = selectedAgentGroupIndexByWorkspace[workspace.id] ?? 0
        let clamped = min(max(current, 0), maxIndex)
        if clamped != current {
            selectedAgentGroupIndexByWorkspace[workspace.id] = clamped
        }
        return clamped
    }

    var activeAgentSessions: [AgentSession] {
        let groups = agentGroups(from: agentSessions)
        let index = selectedAgentGroupIndex
        guard groups.indices.contains(index) else { return [] }
        return groups[index]
    }

    func selectAgentGroup(index: Int) {
        guard let workspace = selectedWorkspace else { return }
        let groups = agentGroups(from: agentSessions)
        guard !groups.isEmpty else { return }
        let clamped = min(max(index, 0), groups.count - 1)
        selectedAgentGroupIndexByWorkspace[workspace.id] = clamped

        let groupSessions = groups[clamped]
        let storedId = selectedAgentIdsByWorkspaceAndGroup[workspace.id]?[clamped]
        if let storedId,
           let session = groupSessions.first(where: { $0.id == storedId }) {
            selectedAgentSession = session
        } else {
            selectedAgentSession = groupSessions.first
        }
        selectedAgentIdByWorkspace[workspace.id] = selectedAgentSession?.id
        if let selectedId = selectedAgentSession?.id {
            var groupSelections = selectedAgentIdsByWorkspaceAndGroup[workspace.id] ?? [:]
            groupSelections[clamped] = selectedId
            selectedAgentIdsByWorkspaceAndGroup[workspace.id] = groupSelections
        }
        persistAgentState(for: workspace)
        if let selected = selectedAgentSession, selected.hasLaunchedCommand {
            selected.focusTerminal()
        }
    }

    func addAgentSession() {
        guard let workspace = selectedWorkspace else { return }
        let workingDir = selectedProject?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let nextIndex = nextAgentIndex(for: workspace.id)
        let session = AgentSession(
            name: "Agent \(nextIndex)",
            workingDirectory: workingDir
        )
        attachSessionCallbacks(session, workspaceId: workspace.id)
        agentSessions.append(session)
        agentSessionsByWorkspace[workspace.id] = agentSessions
        selectAgentSession(session)
    }

    func removeAgentSession(_ session: AgentSession) {
        // Clean up the terminal first
        session.cleanup()

        agentSessions.removeAll { $0.id == session.id }
        if let workspace = selectedWorkspace {
            agentSessionsByWorkspace[workspace.id] = agentSessions
            normalizeSelection(for: workspace)
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
        if let workspace = selectedWorkspace {
            if let index = agentSessions.firstIndex(where: { $0.id == session.id }) {
                let groupIndex = index / agentGroupSize
                selectedAgentGroupIndexByWorkspace[workspace.id] = groupIndex
                var groupSelections = selectedAgentIdsByWorkspaceAndGroup[workspace.id] ?? [:]
                groupSelections[groupIndex] = session.id
                selectedAgentIdsByWorkspaceAndGroup[workspace.id] = groupSelections
            }
            selectedAgentIdByWorkspace[workspace.id] = session.id
            persistAgentState(for: workspace)
        }
        if session.hasLaunchedCommand {
            session.focusTerminal()
        }
    }

    func moveAgentSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard let workspace = selectedWorkspace else { return }
        guard sourceIndex != destinationIndex else { return }
        guard sourceIndex >= 0,
              sourceIndex < agentSessions.count,
              destinationIndex >= 0,
              destinationIndex <= agentSessions.count else { return }

        var sessions = agentSessions
        sessions.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        agentSessions = sessions
        agentSessionsByWorkspace[workspace.id] = sessions
        normalizeSelection(for: workspace)
    }

    func selectAgentSession(id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }) else { return }
        selectAgentSession(session)
    }

    func selectNextAgentSession() {
        let sessions = activeAgentSessions
        guard !sessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = sessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(sessions[0])
            return
        }
        let nextIndex = (index + 1) % sessions.count
        selectAgentSession(sessions[nextIndex])
    }

    func selectPreviousAgentSession() {
        let sessions = activeAgentSessions
        guard !sessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = sessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(sessions[0])
            return
        }
        let prevIndex = (index - 1 + sessions.count) % sessions.count
        selectAgentSession(sessions[prevIndex])
    }

    private func agentGroups(from sessions: [AgentSession]) -> [[AgentSession]] {
        guard !sessions.isEmpty else { return [] }
        var groups: [[AgentSession]] = []
        var index = 0
        while index < sessions.count {
            let end = min(index + agentGroupSize, sessions.count)
            groups.append(Array(sessions[index..<end]))
            index = end
        }
        return groups
    }

    private func activeSessions(for workspaceId: UUID) -> [AgentSession] {
        let sessions = agentSessionsByWorkspace[workspaceId] ?? []
        let groups = agentGroups(from: sessions)
        let maxIndex = max(0, groups.count - 1)
        let currentIndex = selectedAgentGroupIndexByWorkspace[workspaceId] ?? 0
        let clampedIndex = min(max(currentIndex, 0), maxIndex)
        guard groups.indices.contains(clampedIndex) else { return [] }
        return groups[clampedIndex]
    }

    private func normalizeSelection(for workspace: Workspace) {
        let groups = agentGroups(from: agentSessions)
        if groups.isEmpty {
            selectedAgentSession = nil
            selectedAgentIdByWorkspace[workspace.id] = nil
            selectedAgentGroupIndexByWorkspace[workspace.id] = 0
            selectedAgentIdsByWorkspaceAndGroup[workspace.id] = [:]
            persistAgentState(for: workspace)
            return
        }

        let maxIndex = max(0, groups.count - 1)
        let currentIndex = selectedAgentGroupIndexByWorkspace[workspace.id] ?? 0
        let clampedIndex = min(max(currentIndex, 0), maxIndex)
        selectedAgentGroupIndexByWorkspace[workspace.id] = clampedIndex

        let groupSessions = groups[clampedIndex]
        let storedId = selectedAgentIdsByWorkspaceAndGroup[workspace.id]?[clampedIndex]
            ?? selectedAgentIdByWorkspace[workspace.id]
        if let storedId,
           let session = groupSessions.first(where: { $0.id == storedId }) {
            selectedAgentSession = session
        } else {
            selectedAgentSession = groupSessions.first
        }

        selectedAgentIdByWorkspace[workspace.id] = selectedAgentSession?.id
        if let selectedId = selectedAgentSession?.id {
            var groupSelections = selectedAgentIdsByWorkspaceAndGroup[workspace.id] ?? [:]
            groupSelections[clampedIndex] = selectedId
            selectedAgentIdsByWorkspaceAndGroup[workspace.id] = groupSelections
        }
        if let selected = selectedAgentSession, selected.hasLaunchedCommand {
            selected.focusTerminal()
        }
        persistAgentState(for: workspace)
    }

    private func ensureAgentSessions(for workspace: Workspace) {
        if agentSessionsByWorkspace[workspace.id] == nil {
            agentSessionsByWorkspace[workspace.id] = []
        }
        if agentCounterByWorkspace[workspace.id] == nil {
            agentCounterByWorkspace[workspace.id] = 1
        }
        agentSessions = agentSessionsByWorkspace[workspace.id] ?? []
        for session in agentSessions {
            attachSessionCallbacks(session, workspaceId: workspace.id)
        }
        if agentSessions.isEmpty {
            addAgentSession()
        } else {
            let groups = agentGroups(from: agentSessions)
            let maxIndex = max(0, groups.count - 1)
            let currentIndex = selectedAgentGroupIndexByWorkspace[workspace.id] ?? 0
            let clampedIndex = min(max(currentIndex, 0), maxIndex)
            selectedAgentGroupIndexByWorkspace[workspace.id] = clampedIndex

            let groupSessions = groups[clampedIndex]
            let storedId = selectedAgentIdsByWorkspaceAndGroup[workspace.id]?[clampedIndex]
                ?? selectedAgentIdByWorkspace[workspace.id]
            if let storedId,
               let selected = groupSessions.first(where: { $0.id == storedId }) {
                selectedAgentSession = selected
            } else {
                selectedAgentSession = groupSessions.first
            }
            selectedAgentIdByWorkspace[workspace.id] = selectedAgentSession?.id
        }
    }

    private func selectedProjectForWorkspace(_ workspace: Workspace) -> Project? {
        Project(path: workspace.rootPath, name: workspace.name)
    }

    private func nextAgentIndex(for workspaceId: UUID) -> Int {
        let next = (agentCounterByWorkspace[workspaceId] ?? 1)
        agentCounterByWorkspace[workspaceId] = next + 1
        return next
    }

    private func cleanupAgentSessions(for workspaceId: UUID) {
        if let sessions = agentSessionsByWorkspace[workspaceId] {
            for session in sessions {
                session.cleanup()
            }
        }
        agentSessionsByWorkspace[workspaceId] = nil
        selectedAgentIdByWorkspace[workspaceId] = nil
        selectedAgentGroupIndexByWorkspace[workspaceId] = nil
        selectedAgentIdsByWorkspaceAndGroup[workspaceId] = nil
        selectedProjectPathByWorkspace[workspaceId] = nil
        agentCounterByWorkspace[workspaceId] = nil
    }

    private func hydrateAgentStatesFromStorage() {
        let workspaceIds = Set(storage.workspaces.map { $0.id })
        for state in storage.agentStates where workspaceIds.contains(state.workspaceId) {
            let sessions = state.sessions.map { AgentSession(snapshot: $0) }
            for session in sessions {
                attachSessionCallbacks(session, workspaceId: state.workspaceId)
            }
            agentSessionsByWorkspace[state.workspaceId] = sessions
            selectedAgentIdByWorkspace[state.workspaceId] = state.selectedAgentId
            selectedAgentGroupIndexByWorkspace[state.workspaceId] = state.selectedAgentGroupIndex
            selectedAgentIdsByWorkspaceAndGroup[state.workspaceId] = state.selectedAgentIdsByGroup
            selectedProjectPathByWorkspace[state.workspaceId] = state.selectedProjectPath
            let nextIndex = max(state.nextAgentIndex, sessions.count + 1)
            agentCounterByWorkspace[state.workspaceId] = max(1, nextIndex)
        }
    }

    private func syncPlanOrchestrator() {
        let enabled = storage.workspaces.filter { $0.orchestratorEnabled }
        for workspace in enabled {
            ensurePlanFolderExists(for: workspace)
        }
        planOrchestrator.updateWorkspaces(enabled)
    }

    private func persistAgentState(for workspace: Workspace) {
        let sessions = agentSessionsByWorkspace[workspace.id] ?? []
        let snapshots = sessions.map { $0.snapshot() }
        let nextIndex = max(agentCounterByWorkspace[workspace.id] ?? 1, snapshots.count + 1)
        let state = WorkspaceAgentState(
            workspaceId: workspace.id,
            sessions: snapshots,
            selectedAgentId: selectedAgentIdByWorkspace[workspace.id],
            selectedAgentGroupIndex: selectedAgentGroupIndexByWorkspace[workspace.id] ?? 0,
            selectedAgentIdsByGroup: selectedAgentIdsByWorkspaceAndGroup[workspace.id] ?? [:],
            selectedProjectPath: selectedProjectPathByWorkspace[workspace.id],
            nextAgentIndex: nextIndex
        )
        storage.updateAgentState(state)
    }

    private func attachSessionCallbacks(_ session: AgentSession, workspaceId: UUID) {
        session.stateDidChange = { [weak self] in
            guard let self else { return }
            if let workspace = self.storage.workspace(id: workspaceId) {
                self.persistAgentState(for: workspace)
            }
        }
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
