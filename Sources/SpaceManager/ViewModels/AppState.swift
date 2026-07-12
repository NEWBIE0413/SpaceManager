import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태. 워크스페이스 목록 자체는 WorkspaceStorage.shared(전역)가 소유한다.
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared

    let windowStateId: UUID

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
        // windowStateId(let)를 모든 분기에서 먼저 확정해야 한다 — self.storage 접근(구독 설정)은
        // 저장 프로퍼티가 전부 초기화된 뒤에만 허용되므로, claim 판단을 그보다 앞에 끝낸다.
        let claimed = WorkspaceStorage.shared.claimNextWindowState()
        if let claimed {
            windowStateId = claimed.id
        } else {
            windowStateId = UUID()
            WorkspaceStorage.shared.registerClaimed(windowStateId)
        }

        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let claimed {
            restore(from: claimed)
        } else if let first = storage.workspaces.first {
            selectWorkspace(first)
        }
    }

    deinit {
        // 창이 닫히면 그 창의 상태를 제거. 앱 종료 시에는 유지해야 하므로 가드
        // (macOS는 종료 시 deinit을 보장하지 않지만, 호출되는 경우를 방어)
        if !AppTermination.isTerminating {
            WorkspaceStorage.shared.removeWindowState(id: windowStateId)
        }
    }

    private func restore(from state: WindowState) {
        let workspaceIds = Set(storage.workspaces.map(\.id))
        for wsTabs in state.workspaceTabs where workspaceIds.contains(wsTabs.workspaceId) {
            let restored = wsTabs.tabs.map { TerminalSession(snapshot: $0) }
            sessionsByWorkspace[wsTabs.workspaceId] = restored
            if let selectedId = wsTabs.selectedTabId {
                selectedSessionIdByWorkspace[wsTabs.workspaceId] = selectedId
            }
        }
        // 터미널 프로세스는 여기서 시작하지 않는다 — 뷰가 붙고 xterm이 ready될 때 게으르게 시작
        if let wsId = state.selectedWorkspaceId,
           let workspace = storage.workspace(id: wsId) {
            selectWorkspace(workspace)
        } else if let first = storage.workspaces.first {
            selectWorkspace(first)
        }
    }

    private func persistWindowState() {
        var wsStates: [WorkspaceTabsState] = []
        for (wsId, wsSessions) in sessionsByWorkspace where !wsSessions.isEmpty {
            wsStates.append(WorkspaceTabsState(
                workspaceId: wsId,
                selectedTabId: selectedSessionIdByWorkspace[wsId],
                tabs: wsSessions.map { $0.snapshot() }
            ))
        }
        WorkspaceStorage.shared.updateWindowState(WindowState(
            id: windowStateId,
            selectedWorkspaceId: selectedWorkspace?.id,
            workspaceTabs: wsStates
        ))
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

    /// tmux 세션명 커스텀 설정 — 마이그레이션 수단 (기존 세션 이름을 그대로 기입하면 연결됨).
    /// 변경 시 해당 워크스페이스의 메인 탭을 재생성해 새 세션명으로 재attach한다.
    func setTmuxSessionName(_ workspace: Workspace, to raw: String) {
        guard var ws = storage.workspace(id: workspace.id) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        ws.tmuxSessionName = trimmed.isEmpty ? nil : TmuxBootstrap.sanitizeSessionName(trimmed)
        storage.updateWorkspace(ws)
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
        // 메인 탭 재생성 (탭 자체는 detach만 되고 tmux 세션은 무손실)
        var wsSessions = sessionsByWorkspace[ws.id] ?? []
        if let index = wsSessions.firstIndex(where: { $0.kind == .tmuxMain }) {
            wsSessions[index].cleanup()
            wsSessions.remove(at: index)
        }
        sessionsByWorkspace[ws.id] = wsSessions
        if selectedWorkspace?.id == ws.id {
            ensureSessions(for: ws)
            selectedSessionIdByWorkspace[ws.id] = selectedSession?.id
        }
        persistWindowState()
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
        persistWindowState()
    }

    func selectWorkspace(_ workspace: Workspace) {
        if let current = selectedWorkspace {
            sessionsByWorkspace[current.id] = sessions
            selectedSessionIdByWorkspace[current.id] = selectedSession?.id
        }
        selectedWorkspace = workspace
        selectedProject = Project(path: workspace.rootPath, name: workspace.name)
        ensureSessions(for: workspace)
        persistWindowState()
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
        persistWindowState()
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
        persistWindowState()
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
        persistWindowState()
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
        persistWindowState()
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
