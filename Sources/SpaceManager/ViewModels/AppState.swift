import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태. 워크스페이스 목록 자체는 WorkspaceStorage.shared(전역)가 소유한다.
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared

    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    @Published var sessions: [TerminalSession] = []
    @Published var selectedSession: TerminalSession?
    private var sessionsByWorkspace: [UUID: [TerminalSession]] = [:]
    private var selectedSessionIdByWorkspace: [UUID: UUID] = [:]

    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        if let sessions = sessionsByWorkspace[workspace.id] {
            for session in sessions { session.cleanup() }
        }
        sessionsByWorkspace[workspace.id] = nil
        selectedSessionIdByWorkspace[workspace.id] = nil
        if selectedWorkspace?.id == workspace.id {
            if let next = storage.workspaces.first {
                selectWorkspace(next)
            } else {
                selectedWorkspace = nil
                selectedProject = nil
                sessions = []
                selectedSession = nil
            }
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
        if let current = selectedWorkspace {
            sessionsByWorkspace[current.id] = sessions
            selectedSessionIdByWorkspace[current.id] = selectedSession?.id
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

    /// 순수 셸 탭 (Cmd+T)
    func addShellTab() {
        guard let workspace = selectedWorkspace else { return }
        let session = TerminalSession(
            kind: .shell,
            name: "zsh",
            workingDirectory: workspace.rootPath
        )
        appendAndSelect(session, in: workspace)
    }

    /// 추가 tmux 탭 — <세션명>-2, -3, … 자동 넘버링
    func addTmuxTab() {
        guard let workspace = selectedWorkspace else { return }
        let base = workspace.effectiveTmuxSessionName
        let used = Set(sessions.compactMap { $0.tmuxSessionName })
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        let sessionName = "\(base)-\(n)"
        let session = TerminalSession(
            kind: .tmuxExtra,
            name: sessionName,
            workingDirectory: workspace.rootPath,
            tmuxSessionName: sessionName
        )
        appendAndSelect(session, in: workspace)
    }

    private func makeMainTab(for workspace: Workspace) -> TerminalSession {
        // tmux가 없으면 메인 탭도 순수 셸로 폴백 (배너는 TerminalAreaView가 표시)
        guard TmuxBootstrap.isTmuxAvailable else {
            return TerminalSession(kind: .shell, name: "zsh", workingDirectory: workspace.rootPath)
        }
        let sessionName = workspace.effectiveTmuxSessionName
        return TerminalSession(
            kind: .tmuxMain,
            name: sessionName,
            workingDirectory: workspace.rootPath,
            tmuxSessionName: sessionName
        )
    }

    private func appendAndSelect(_ session: TerminalSession, in workspace: Workspace) {
        sessions.append(session)
        sessionsByWorkspace[workspace.id] = sessions
        selectSession(session)
    }

    func removeSession(_ session: TerminalSession) {
        session.cleanup()
        sessions.removeAll { $0.id == session.id }
        if let workspace = selectedWorkspace {
            sessionsByWorkspace[workspace.id] = sessions
        }
        if selectedSession?.id == session.id {
            selectedSession = sessions.first
        }
    }

    func selectSession(_ session: TerminalSession) {
        guard selectedSession?.id != session.id else {
            session.focusTerminal()
            return
        }
        selectedSession = session
        if let workspace = selectedWorkspace {
            selectedSessionIdByWorkspace[workspace.id] = session.id
        }
        session.restartIfDead()
        session.focusTerminal()
    }

    func selectSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectSession(session)
    }

    func moveSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < sessions.count,
              destinationIndex >= 0, destinationIndex <= sessions.count else { return }
        var updated = sessions
        updated.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        sessions = updated
        if let workspace = selectedWorkspace {
            sessionsByWorkspace[workspace.id] = updated
        }
    }

    func selectNextSession() {
        guard !sessions.isEmpty else { return }
        guard let current = selectedSession,
              let index = sessions.firstIndex(where: { $0.id == current.id }) else {
            selectSession(sessions[0])
            return
        }
        selectSession(sessions[(index + 1) % sessions.count])
    }

    func selectPreviousSession() {
        guard !sessions.isEmpty else { return }
        guard let current = selectedSession,
              let index = sessions.firstIndex(where: { $0.id == current.id }) else {
            selectSession(sessions[0])
            return
        }
        selectSession(sessions[(index - 1 + sessions.count) % sessions.count])
    }

    private func ensureSessions(for workspace: Workspace) {
        sessions = sessionsByWorkspace[workspace.id] ?? []
        // 메인 탭 보장: 닫혔거나 처음이면 재생성 → tmux 세션에 재attach (스펙 §5)
        if !sessions.contains(where: { $0.kind == .tmuxMain }) && TmuxBootstrap.isTmuxAvailable {
            let main = makeMainTab(for: workspace)
            sessions.insert(main, at: 0)
        }
        if sessions.isEmpty {
            sessions = [makeMainTab(for: workspace)]
        }
        sessionsByWorkspace[workspace.id] = sessions
        let storedId = selectedSessionIdByWorkspace[workspace.id]
        selectedSession = sessions.first(where: { $0.id == storedId }) ?? sessions.first
    }
}
