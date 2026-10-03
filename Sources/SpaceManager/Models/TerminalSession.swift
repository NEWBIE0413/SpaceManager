import Foundation
import SwiftUI
import Combine

enum TabKind: String, Codable {
    case tmuxMain    // 워크스페이스 고정 탭 — 워크스페이스 tmux 세션에 attach
    case shell       // 순수 셸 탭 — 앱 재시작 시 새 셸로 시작 (복구 없음, 명시적 한계)
    case tmuxExtra   // 추가 tmux 탭 — <세션명>-N, 재부팅 후에도 복구됨
    case quick       // 홈에서 로그인 셸로 ccv를 직접 실행하는 일회성 대화 PTY
}

/// 터미널 탭 하나. PTYProcess + TerminalWebView 쌍을 소유해
/// SwiftUI 뷰 업데이트를 넘어 터미널을 살아있게 한다 (기존 세션 소유 패턴 계승).
final class TerminalSession: Identifiable, ObservableObject, Equatable {
    let id: UUID
    let kind: TabKind
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var startError: String?
    /// 원격 tmux 연결이 끊겨 다시 붙는 중. 새 연결이 첫 출력을 보낼 때까지 유지된다 —
    /// ssh 접속(프록시 경유 수 초) 동안에도 화면은 끊기기 전 그대로 두고 배지만 띄운다.
    @Published private(set) var isReconnecting = false
    /// 마지막으로 실패한 연결에서 ssh가 남긴 한 줄. 배지 툴팁에만 쓴다.
    @Published private(set) var lastConnectionFailure: String?
    var workingDirectory: String
    /// tmuxMain/tmuxExtra가 attach할 세션명 (shell이면 nil)
    let tmuxSessionName: String?
    /// ssh 호스트 별칭. 설정되면 tmux 서버(또는 셸)가 그 호스트에서 돈다.
    let remoteHost: String?
    let quickLaunch: QuickLaunch?
    let quickConfiguration: QuickSessionConfiguration
    private let initialName: String

    private(set) var terminalView: TerminalWebView?
    private var pty: PTYProcess?
    private var started = false
    private var quickSessionId: String?
    private var quickIdentityTimer: Timer?
    private var quickTitleCancellable: AnyCancellable?
    private var isTrackingQuickTitle = false
    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0
    /// 원격 tmux 탭의 ssh stderr. 탭 id가 아니라 객체마다 따로 둔다 — 호스트 전환은 같은
    /// id로 새 세션을 만들기 때문에, 옛 객체가 정리되며 새 객체의 로그를 지우면 안 된다.
    let sshErrorLogPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("space-manager-ssh-\(UUID().uuidString).log")

    init(id: UUID = UUID(), kind: TabKind, name: String,
         workingDirectory: String, tmuxSessionName: String? = nil,
         remoteHost: String? = nil,
         quickLaunch: QuickLaunch? = nil,
         quickConfiguration: QuickSessionConfiguration = .default) {
        self.id = id
        self.kind = kind
        self.name = name
        self.initialName = name
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
        self.remoteHost = remoteHost
        self.quickLaunch = quickLaunch
        self.quickConfiguration = quickConfiguration
        self.quickSessionId = quickLaunch?.resumeSessionId
    }

    func getOrCreateTerminal() -> TerminalWebView {
        if let existing = terminalView { return existing }
        let palette: TerminalPalette = kind == .quick ? .quickLight : .workspaceDark
        let view = TerminalWebView(frame: .zero, palette: palette)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onUserInput = { [weak self] data in
            // 재연결 중 화면은 지난 스냅숏이다. 접속 중인 ssh는 아직 cooked 모드라 입력을
            // 로컬 에코로 화면에 덧쓰고, 접속 뒤에는 모아 둔 키를 원격 tmux에 쏟아낸다.
            guard let self, self.acceptsInput else { return }
            self.pty?.write(data)
        }
        view.onResize = { [weak self] cols, rows in self?.pty?.resize(cols: cols, rows: rows) }
        // PTY는 xterm 페이지 ready 이후에 시작해야 초기 출력이 유실되지 않는다
        view.onReady = { [weak self] in self?.startIfNeeded() }
        view.onWebProcessCrash = { [weak self] in self?.recoverFromCrash() }
        terminalView = view
        return view
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        startPTY()
    }

    /// Quick은 클릭 순간 WebView 로드와 Claude 기동을 함께 시작한다. xterm이 아직
    /// ready가 아니어도 TerminalWebView.feed가 pendingOutput에 보관하고 ready 때
    /// flush하므로 초기 출력 유실 없이 두 비싼 준비 단계를 겹칠 수 있다.
    func startQuickImmediately() {
        guard kind == .quick else { return }
        _ = getOrCreateTerminal()
        startIfNeeded()
    }

    private func startPTY() {
        cancelReconnectTimer()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if kind == .quick {
            env = QuickSessionPolicy.applyingEnvironment(
                env,
                launch: quickLaunch ?? .blank,
                configuration: quickConfiguration
            )
        }

        if kind == .quick {
            workingDirectory = QuickSessionPolicy.ensureWorkingDirectory()
        }
        let startDir = FileManager.default.fileExists(atPath: workingDirectory)
            ? workingDirectory : NSHomeDirectory()
        let arguments = Self.launchArguments(
            kind: kind,
            tmuxSessionName: tmuxSessionName,
            workingDirectory: startDir,
            remoteHost: remoteHost,
            // 원격 디렉토리는 폴백 전 원래 경로에서 계산한다 — 로컬에 없어도 원격엔 있다.
            remoteDirectory: TmuxBootstrap.remoteDirectory(forLocalPath: workingDirectory),
            quickLaunch: quickLaunch,
            quickConfiguration: quickConfiguration,
            sshErrorLog: sshErrorLogPath
        )

        let pty = PTYProcess()
        let view = terminalView
        let firstOutput = isReconnecting ? FirstOutputLatch() : nil
        pty.onOutput = { [weak self, weak view, weak pty] data in
            view?.feed(data)   // feed 내부에서 메인 큐 배칭
            // 원격의 첫 바이트 = tmux attach의 전체 재도장. ssh 자신의 오류는 로그로 빠지므로
            // 접속 실패는 여기 오지 않는다. 한계: 원격 스크립트가 tmux 전에 실패하면(systemctl 등)
            // 그 오류가 첫 바이트로 화면에 찍히고 배지가 잠깐 내려간다 — 잦아지면 tmux의
            // alt-screen 진입(ESC[?1049h)을 볼 때까지 출력을 붙잡는 방식으로 바꾼다.
            guard let firstOutput, firstOutput.fire() else { return }
            DispatchQueue.main.async {
                guard let self, let pty, self.pty === pty else { return }
                self.connectionResumed()
            }
        }
        let launchedAt = Date()
        pty.onExit = { [weak self, weak pty] code in
            DispatchQueue.main.async {
                guard let self, let pty, self.pty === pty, self.started else { return }
                self.isRunning = false
                self.handleExit(exitCode: code, connectedFor: Date().timeIntervalSince(launchedAt))
            }
        }
        do {
            try pty.start(
                executable: shell, execName: execName, arguments: arguments,
                environment: env, workingDirectory: startDir,
                cols: view?.lastCols ?? 80, rows: view?.lastRows ?? 24
            )
            self.pty = pty
            isRunning = true
            startError = nil
            if kind == .quick, let processIdentifier = pty.processIdentifier {
                beginQuickTitleUpdates(processIdentifier: processIdentifier)
            }
        } catch {
            startError = "터미널 시작 실패: \(error)"
            isRunning = false
        }
    }

    private func beginQuickTitleUpdates(processIdentifier: pid_t) {
        let scanner = QuickConversationScanner.shared
        if isTrackingQuickTitle { scanner.untrack(owner: id) }
        isTrackingQuickTitle = false
        if quickLaunch?.resumeSessionId == nil {
            quickSessionId = nil
            name = initialName
        }
        quickTitleCancellable = scanner.$aiTitlesBySessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] titles in
                self?.updateQuickTitle(titlesBySessionId: titles)
            }
        scanner.start()
        trackQuickTitle()
        scanner.rescan()

        guard quickSessionId == nil else { return }
        resolveQuickSessionId(processIdentifier: processIdentifier)
        guard quickSessionId == nil else { return }
        quickIdentityTimer?.invalidate()
        quickIdentityTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] timer in
            guard let self, self.isRunning else {
                timer.invalidate()
                return
            }
            self.resolveQuickSessionId(processIdentifier: processIdentifier)
            if self.quickSessionId != nil {
                timer.invalidate()
                self.quickIdentityTimer = nil
            }
        }
    }

    private func resolveQuickSessionId(processIdentifier: pid_t) {
        guard quickSessionId == nil,
              let sessionId = QuickSessionTitleResolver.sessionId(
                processIdentifier: processIdentifier
              ) else { return }
        quickSessionId = sessionId
        trackQuickTitle()
        updateQuickTitle(
            titlesBySessionId: QuickConversationScanner.shared.aiTitlesBySessionId
        )
        QuickConversationScanner.shared.rescan()
    }

    private func trackQuickTitle() {
        guard let quickSessionId else { return }
        QuickConversationScanner.shared.track(sessionID: quickSessionId, owner: id)
        isTrackingQuickTitle = true
    }

    func updateQuickTitle(titlesBySessionId: [String: String]) {
        guard kind == .quick,
              let quickSessionId,
              let title = titlesBySessionId[quickSessionId] else { return }
        name = title
    }

    func matchesQuickConversation(sessionId: String) -> Bool {
        kind == .quick && quickSessionId == sessionId
    }

    /// 죽은 탭 재시작 (프로세스 종료·시작 실패 후 재시도)
    func restartIfDead() {
        guard started, pty?.isRunning != true else { return }
        cancelReconnectTimer()
        pty?.terminate()
        pty = nil
        startError = nil
        startPTY()
    }

    /// PTY 종료 처리. 원격 tmux의 비정상 종료만 재연결하고, 그 동안 터미널 화면은
    /// 끊기기 전 마지막 프레임을 유지한다 (오류 화면으로 바꾸지 않는다).
    func handleExit(exitCode: Int32, connectedFor: TimeInterval) {
        guard let delay = RemoteReconnectPolicy.delay(kind: kind, remoteHost: remoteHost,
            exitCode: exitCode, attempt: reconnectAttempt, connectedFor: connectedFor) else {
            // detach(0)처럼 의도된 종료는 재시도 배지를 남기지 않는다.
            isReconnecting = false
            return
        }
        if connectedFor >= 30 { reconnectAttempt = 0 }
        reconnectAttempt += 1
        lastConnectionFailure = Self.lastLogLine(at: sshErrorLogPath) ?? lastConnectionFailure
        isReconnecting = true
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.restartIfDead()
        }
    }

    /// 새 연결이 원격 화면을 보내기 시작했다 — 배지를 내리고 입력을 다시 받는다.
    func connectionResumed() {
        guard isReconnecting else { return }
        isReconnecting = false
        lastConnectionFailure = nil
    }

    var acceptsInput: Bool { !isReconnecting }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// ssh 로그의 마지막 비어 있지 않은 줄. 접속마다 `2>`로 새로 쓰므로 직전 시도의 원인이다.
    static func lastLogLine(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data.suffix(4096), encoding: .utf8) ?? String(data: data.suffix(4096), encoding: .isoLatin1) else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map { String($0.prefix(240)) }
    }

    /// CLI도 화면 선택과 같은 경로로 죽은 연결을 복구한다. 실행 중인 tmux는 건드리지 않는다.
    func reconnectIfNeeded() {
        _ = getOrCreateTerminal()
        restartIfDead()
    }

    func retargeted(to host: String?) -> TerminalSession {
        // 셸 탭 이름은 실행 위치를 말한다 ("zsh" / "shell@arch"). 위치가 바뀌면 함께 바꾼다.
        let retargetedName = kind == .shell && name == Self.defaultShellName(remoteHost: remoteHost)
            ? Self.defaultShellName(remoteHost: host) : name
        return TerminalSession(id: id, kind: kind, name: retargetedName, workingDirectory: workingDirectory,
                               tmuxSessionName: tmuxSessionName, remoteHost: host,
                               quickLaunch: quickLaunch, quickConfiguration: quickConfiguration)
    }

    static func defaultShellName(remoteHost: String?) -> String {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return "zsh" }
        return "shell@\(host)"
    }

    /// WKWebView 프로세스 크래시: 페이지 리로드 + PTY 재시작.
    /// tmux 세션은 서버에 살아있으므로 재attach로 무손실 복구된다 (스펙 §7).
    private func recoverFromCrash() {
        cancelReconnectTimer()
        pty?.terminate()
        pty = nil
        started = false          // 리로드 후 ready가 다시 오면 startIfNeeded가 재시작
        terminalView?.reloadPage()
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.focusTerminal()
        }
    }

    func cleanup(force: Bool = false) {
        started = false
        cancelReconnectTimer()
        isReconnecting = false
        try? FileManager.default.removeItem(atPath: sshErrorLogPath)
        if isTrackingQuickTitle { QuickConversationScanner.shared.untrack(owner: id) }
        isTrackingQuickTitle = false
        quickIdentityTimer?.invalidate()
        quickIdentityTimer = nil
        quickTitleCancellable = nil
        pty?.terminate(force: force)
        pty = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    deinit {
        reconnectTimer?.invalidate()
        try? FileManager.default.removeItem(atPath: sshErrorLogPath)
        quickIdentityTimer?.invalidate()
        if isTrackingQuickTitle { QuickConversationScanner.shared.untrack(owner: id) }
    }

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }

    /// PTY 실행 정책을 순수 함수로 분리해 Quick이 TmuxBootstrap을 절대 거치지
    /// 않는다는 경계를 테스트할 수 있게 한다.
    static func launchArguments(
        kind: TabKind,
        tmuxSessionName: String?,
        workingDirectory: String,
        remoteHost: String? = nil,
        remoteDirectory: TmuxBootstrap.RemoteDirectory? = nil,
        quickLaunch: QuickLaunch? = nil,
        quickConfiguration: QuickSessionConfiguration = .default,
        sshErrorLog: String? = nil
    ) -> [String] {
        if kind == .quick {
            return ["-lc", QuickSessionPolicy.launchCommand(
                for: quickLaunch ?? .blank,
                configuration: quickConfiguration
            )]
        }
        // 원격: 로컬 셸은 ssh만 exec한다. tmux 콜드부트 판단은 원격 스크립트가 한다.
        if let remoteHost, !remoteHost.trimmingCharacters(in: .whitespaces).isEmpty {
            let dir = remoteDirectory ?? TmuxBootstrap.remoteDirectory(forLocalPath: workingDirectory)
            if let tmuxSessionName {
                let script = TmuxBootstrap.remoteStartupScript(sessionName: tmuxSessionName, remoteDirectory: dir)
                return ["-lc", TmuxBootstrap.remoteLaunchCommand(host: remoteHost, remoteScript: script, errorLog: sshErrorLog)]
            }
            return ["-lc", TmuxBootstrap.remoteShellCommand(host: remoteHost, remoteDirectory: dir)]
        }
        if let tmuxSessionName {
            return ["-lc", TmuxBootstrap.startupScript(
                sessionName: tmuxSessionName,
                workingDirectory: workingDirectory
            )]
        }
        return []   // 순수 인터랙티브 로그인 셸
    }
}

/// Only a persistent remote tmux attachment is retried. A deliberate detach (0),
/// a shell exit or a Quick conversation must stay closed. Cap retries while a host sleeps.
enum RemoteReconnectPolicy {
    static func delay(kind: TabKind, remoteHost: String?, exitCode: Int32,
                      attempt: Int, connectedFor: TimeInterval) -> TimeInterval? {
        guard kind == .tmuxMain || kind == .tmuxExtra,
              let remoteHost, !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              exitCode != 0 else { return nil }
        let failures = connectedFor >= 30 ? 0 : min(4, max(0, attempt))
        return min(30, 3 * pow(2, Double(failures)))
    }
}

/// PTY io 큐에서만 만지는 일회성 플래그 — 첫 출력에서 한 번만 메인으로 알린다.
private final class FirstOutputLatch {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

private extension QuickLaunch {
    var resumeSessionId: String? {
        guard case .resume(let sessionId) = self else { return nil }
        return sessionId
    }
}

extension TerminalSession {
    convenience init(snapshot: TabSnapshot) {
        self.init(id: snapshot.id, kind: snapshot.kind, name: snapshot.name,
                  workingDirectory: snapshot.workingDirectory,
                  tmuxSessionName: snapshot.tmuxSessionName,
                  remoteHost: snapshot.remoteHost)
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, kind: kind, name: name,
                    workingDirectory: workingDirectory,
                    tmuxSessionName: tmuxSessionName,
                    remoteHost: remoteHost)
    }
}
