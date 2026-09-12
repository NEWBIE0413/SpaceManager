import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태. 워크스페이스 목록 자체는 WorkspaceStorage.shared(전역)가 소유한다.
class AppState: ObservableObject {
    let storage = WorkspaceStorage.shared

    let windowKind: WindowKind
    let windowStateId: UUID
    let shouldCloseOnAppearance: Bool

    /// NSWindow가 다시 붙을 때 적용할 일반 프레임과 표시 상태.
    private(set) var restoredWindowFrame: WindowFrameState?
    private(set) var restoredWindowIsZoomed = false
    private(set) var restoredWindowIsFullscreen = false

    /// 이 창이 소유한 워크스페이스 목록 (창별 독립 — 전역 공유 아님)
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    @Published var sessions: [TerminalSession] = []
    @Published var selectedSession: TerminalSession? {
        didSet { observeSelectedSession() }
    }
    private var sessionsByWorkspace: [UUID: [TerminalSession]] = [:]
    private var selectedSessionIdByWorkspace: [UUID: UUID] = [:]
    private var selectedSessionObservation: AnyCancellable?

    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false

    /// 창별 라이트/다크 — 전역(NSApp)이 아니라 이 창의 NSWindow.appearance에 적용된다.
    /// 레거시 전역 선택(UserDefaults)을 새 창의 기본값으로 승계한다.
    @Published var preferredAppearance: String =
        UserDefaults.standard.string(forKey: "preferredAppearance") ?? "system"

    init(windowKind: WindowKind = .workspace, requestedWindowStateId: UUID? = nil) {
        self.windowKind = windowKind
        // windowStateId(let)를 모든 분기에서 먼저 확정해야 한다 — self.storage 접근(구독 설정)은
        // 저장 프로퍼티가 전부 초기화된 뒤에만 허용되므로, claim 판단을 그보다 앞에 끝낸다.
        let sharedStorage = WorkspaceStorage.shared
        let discardRequestedState = requestedWindowStateId.flatMap { requestedID in
            sharedStorage.windowStates.first { $0.id == requestedID && $0.resolvedKind == windowKind }
        }.map(WorkspaceStorage.isDiscardableEmptyWorkspaceState) ?? false
        shouldCloseOnAppearance = discardRequestedState
        if discardRequestedState, let requestedWindowStateId {
            sharedStorage.removeWindowState(id: requestedWindowStateId)
        }
        let claimed: WindowState?
        if let requestedWindowStateId, !discardRequestedState {
            claimed = sharedStorage.claimWindowState(id: requestedWindowStateId, kind: windowKind)
        } else {
            // scene value가 없던 구 버전/최초 기본 창만 순번 migration을 거친다.
            claimed = sharedStorage.claimNextWindowState(kind: windowKind)
        }
        if let claimed {
            windowStateId = claimed.id
        } else {
            // 같은 scene ID가 중복 생성돼 이미 claim된 경우 한 상태를 두 창이 공유하지 않는다.
            if let requestedWindowStateId,
               !sharedStorage.containsWindowState(id: requestedWindowStateId) {
                windowStateId = requestedWindowStateId
            } else {
                windowStateId = UUID()
            }
            sharedStorage.registerClaimed(windowStateId, kind: windowKind)
        }

        if windowKind == .quick {
            preferredAppearance = "light"
        }
        if let claimed {
            restore(from: claimed)
        } else if windowKind == .quick {
            // 비어 있는 Quick 창도 창 종류 자체가 재시작 뒤 복원되어야 한다.
            persistWindowState()
        } else if storage.windowStates.isEmpty && !storage.workspaces.isEmpty {
            // 업그레이드 경로: 창 상태가 하나도 없으면 레거시 전역 목록(workspaces.json)을
            // 첫 창으로 1회 이관한다. 이후 생성되는 새 창(Cmd+N)은 빈 목록으로 시작.
            workspaces = storage.workspaces
            if let first = workspaces.first {
                selectWorkspace(first)
            } else {
                persistWindowState()
            }
        }
        // 새 창은 빈 워크스페이스 목록으로 시작한다
        WorkspaceWindowRegistry.shared.register(self)
    }

    deinit {
        WorkspaceWindowRegistry.shared.unregister(self)
        // 창이 닫히면 그 창의 상태를 제거. 앱 종료 시에는 유지해야 하므로 가드
        // (macOS는 종료 시 deinit을 보장하지 않지만, 호출되는 경우를 방어)
        if !AppTermination.isTerminating {
            WorkspaceStorage.shared.removeWindowState(id: windowStateId)
        }
    }

    private func restore(from state: WindowState) {
        restoredWindowFrame = state.frame
        restoredWindowIsZoomed = state.resolvedIsZoomed
        restoredWindowIsFullscreen = state.resolvedIsFullscreen

        if windowKind == .quick {
            // Quick 탭은 브라우저 탭처럼 프로세스 수명만 가진다. 창 종류만 복원하고
            // 이전 대화 PTY는 되살리지 않는다 (대화 자체는 ccv transcript에 남는다).
            sessions = []
            selectedSession = nil
            preferredAppearance = "light"
            return
        }

        // 레거시 상태(workspaces 없음)는 전역 목록에서 1회 이관
        workspaces = state.workspaces ?? storage.workspaces
        if let appearance = state.appearance {
            preferredAppearance = appearance
        }
        let workspaceIds = Set(workspaces.map(\.id))
        for wsTabs in state.workspaceTabs where workspaceIds.contains(wsTabs.workspaceId) {
            let restored = wsTabs.tabs.map { TerminalSession(snapshot: $0) }
            sessionsByWorkspace[wsTabs.workspaceId] = restored
            if let selectedId = wsTabs.selectedTabId {
                selectedSessionIdByWorkspace[wsTabs.workspaceId] = selectedId
            }
        }
        // 터미널 프로세스는 여기서 시작하지 않는다 — 뷰가 붙고 xterm이 ready될 때 게으르게 시작
        if let wsId = state.selectedWorkspaceId,
           let workspace = workspaces.first(where: { $0.id == wsId }) {
            selectWorkspace(workspace)
        } else if let first = workspaces.first {
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
            kind: windowKind,
            selectedWorkspaceId: selectedWorkspace?.id,
            workspaces: workspaces,
            workspaceTabs: wsStates,
            appearance: preferredAppearance,
            frame: restoredWindowFrame,
            isZoomed: restoredWindowIsZoomed,
            isFullscreen: restoredWindowIsFullscreen
        ))
    }

    /// 이동/리사이즈 알림에서 호출된다. 확대·전체화면 중에는 일반 프레임을 덮지 않는다.
    func updateWindowPresentation(
        frame: WindowFrameState?,
        isZoomed: Bool,
        isFullscreen: Bool
    ) {
        if let frame {
            restoredWindowFrame = frame
        }
        restoredWindowIsZoomed = isZoomed
        restoredWindowIsFullscreen = isFullscreen
        persistWindowState()
    }

    func setAppearance(_ raw: String) {
        guard windowKind == .workspace else { return }
        preferredAppearance = raw
        persistWindowState()
    }

    private func observeSelectedSession() {
        selectedSessionObservation = selectedSession?.objectWillChange.sink { [weak self] _ in
            // TerminalSession.objectWillChange는 name 변경 직전에 오므로 새 값을 읽는
            // 다음 main turn에 AppState를 무효화해 ContentView의 NSWindow.title도 갱신한다.
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Workspace Management

    func createWorkspace(rootPath: String, customName: String? = nil) {
        let workspace = Workspace(rootPath: rootPath, customName: customName)
        workspaces.append(workspace)
        selectWorkspace(workspace)
    }

    private func workspaceIndex(id: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String?) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        workspaces[index].rename(to: newName)
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = workspaces[index]
        }
        persistWindowState()
    }

    func moveWorkspace(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < workspaces.count,
              destinationIndex >= 0, destinationIndex <= workspaces.count else { return }
        var updated = workspaces
        updated.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        workspaces = updated
        persistWindowState()
    }

    /// tmux 세션명 커스텀 설정 — 마이그레이션 수단 (기존 세션 이름을 그대로 기입하면 연결됨).
    /// 변경 시 해당 워크스페이스의 메인 탭을 재생성해 새 세션명으로 재attach한다.
    func setTmuxSessionName(_ workspace: Workspace, to raw: String) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].tmuxSessionName = trimmed.isEmpty ? nil : TmuxBootstrap.sanitizeSessionName(trimmed)
        let ws = workspaces[index]
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

    /// 원격 호스트 변경. 탭은 detach만 되고 tmux 세션은 어느 쪽 머신에서든 무손실.
    func setRemoteHost(_ workspace: Workspace, to raw: String) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].remoteHost = trimmed.isEmpty ? nil : trimmed
        workspaces[index].updatedAt = Date()
        let ws = workspaces[index]
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
        // 호스트가 바뀌면 이 워크스페이스의 모든 탭을 다시 붙여야 한다
        for session in sessionsByWorkspace[ws.id] ?? [] { session.cleanup() }
        sessionsByWorkspace[ws.id] = []
        if selectedWorkspace?.id == ws.id {
            ensureSessions(for: ws)
            selectedSessionIdByWorkspace[ws.id] = selectedSession?.id
        }
        persistWindowState()
    }

    func deleteWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        if let sessions = sessionsByWorkspace[workspace.id] {
            for session in sessions { session.cleanup() }
        }
        sessionsByWorkspace[workspace.id] = nil
        selectedSessionIdByWorkspace[workspace.id] = nil
        if selectedWorkspace?.id == workspace.id {
            if let next = workspaces.first {
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
        guard let selected = selectedWorkspace,
              let index = workspaceIndex(id: selected.id) else { return }
        workspaces[index].addProject(Project(path: path))
        selectedWorkspace = workspaces[index]
        persistWindowState()
    }

    func removeProject(_ project: Project) {
        guard let selected = selectedWorkspace,
              let index = workspaceIndex(id: selected.id) else { return }
        workspaces[index].removeProject(id: project.id)
        selectedWorkspace = workspaces[index]
        if selectedProject?.id == project.id {
            selectedProject = workspaces[index].projects.first
        }
        persistWindowState()
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
            name: workspace.isRemote ? "shell@\(workspace.remoteHost ?? "")" : "zsh",
            workingDirectory: workspace.rootPath,
            remoteHost: workspace.remoteHost
        )
        appendAndSelect(session, in: workspace)
    }

    func addDefaultTab() {
        if windowKind == .quick {
            addQuickSession()
        } else {
            addShellTab()
        }
    }

    /// 폴더나 이름 입력 없이 홈에서 Claude 대화를 즉시 시작한다.
    func addQuickSession(
        initialPrompt: String? = nil,
        resumeSessionId: String? = nil,
        configuration: QuickSessionConfiguration = .default
    ) {
        guard windowKind == .quick else { return }
        let launch: QuickLaunch
        if let resumeSessionId, UUID(uuidString: resumeSessionId) != nil {
            launch = .resume(sessionId: resumeSessionId)
        } else if let initialPrompt {
            let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            launch = trimmed.isEmpty ? .blank : .initialPrompt(trimmed)
        } else {
            launch = .blank
        }
        let session = TerminalSession(
            kind: .quick,
            name: QuickSessionPolicy.initialSessionName,
            workingDirectory: QuickSessionPolicy.ensureWorkingDirectory(),
            quickLaunch: launch,
            quickConfiguration: configuration
        )
        sessions.append(session)
        selectSession(session)
        session.startQuickImmediately()
    }

    func resumeQuickConversation(sessionId: String) {
        if let existing = sessions.first(where: {
            $0.matchesQuickConversation(sessionId: sessionId)
        }) {
            selectSession(existing)
            return
        }
        addQuickSession(resumeSessionId: sessionId)
    }

    /// 사이드바의 "새 대화"는 프로세스를 미리 띄우지 않고 Hermes 홈으로 돌아간다.
    /// 기존 Quick 탭은 열린 채 유지하며, Cmd+T만 즉시 blank 세션을 시작한다.
    func showQuickHome() {
        guard windowKind == .quick else { return }
        selectedSession = nil
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
            tmuxSessionName: sessionName,
            remoteHost: workspace.remoteHost
        )
        appendAndSelect(session, in: workspace)
    }

    private func makeMainTab(for workspace: Workspace) -> TerminalSession {
        // tmux가 없으면 메인 탭도 순수 셸로 폴백 (배너는 TerminalAreaView가 표시).
        // 원격 워크스페이스는 로컬 tmux가 필요 없다 — 서버가 저쪽에 있다.
        guard TmuxBootstrap.isTmuxAvailable || workspace.isRemote else {
            return TerminalSession(kind: .shell, name: "zsh", workingDirectory: workspace.rootPath)
        }
        let sessionName = workspace.effectiveTmuxSessionName
        return TerminalSession(
            kind: .tmuxMain,
            name: sessionName,
            workingDirectory: workspace.rootPath,
            tmuxSessionName: sessionName,
            remoteHost: workspace.remoteHost
        )
    }

    /// 선택되지 않은 워크스페이스의 탭도 CLI가 나열할 수 있게 한다 (읽기 전용).
    func sessions(for workspace: Workspace) -> [TerminalSession] {
        if selectedWorkspace?.id == workspace.id { return sessions }
        return sessionsByWorkspace[workspace.id] ?? []
    }

    private func appendAndSelect(_ session: TerminalSession, in workspace: Workspace) {
        sessions.append(session)
        sessionsByWorkspace[workspace.id] = sessions
        selectSession(session)
        persistWindowState()
    }

    func removeSession(_ session: TerminalSession) {
        if windowKind == .quick {
            removeQuickSession(session)
            return
        }
        // 메인 탭은 닫기 대상이 아니다 — ensureSessions가 다음 방문에 어차피 재생성하므로
        // 여기서 지우면 "지워졌다가 되살아나는" 유령 삭제가 된다. UI(WorkspaceTabRow)도
        // 메인 탭엔 ×를 숨기지만, 진입점이 늘어도 안전하도록 모델에서도 막는다.
        guard session.kind != .tmuxMain else { return }
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

    /// Quick의 ×는 PTY만 즉시 종료한다. tmux 세션이 없으므로 detach/kill 구분도,
    /// 확인 대화상자도 없다.
    func removeQuickSession(_ session: TerminalSession) {
        guard windowKind == .quick, session.kind == .quick else { return }
        session.cleanup(force: true)
        sessions.removeAll { $0.id == session.id }
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
        // Quick 탭/선택은 의도적으로 복원하지 않으므로 클릭 경로에서
        // window-states.json 원자 쓰기를 하지 않는다.
        if windowKind == .workspace {
            persistWindowState()
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
