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
    var workingDirectory: String
    /// tmuxMain/tmuxExtra가 attach할 세션명 (shell이면 nil)
    let tmuxSessionName: String?
    let quickLaunch: QuickLaunch?
    private let initialName: String

    private(set) var terminalView: TerminalWebView?
    private var pty: PTYProcess?
    private var started = false
    private var quickSessionId: String?
    private var quickIdentityTimer: Timer?
    private var quickTitleCancellable: AnyCancellable?

    init(id: UUID = UUID(), kind: TabKind, name: String,
         workingDirectory: String, tmuxSessionName: String? = nil,
         quickLaunch: QuickLaunch? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.initialName = name
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
        self.quickLaunch = quickLaunch
        self.quickSessionId = quickLaunch?.resumeSessionId
    }

    func getOrCreateTerminal() -> TerminalWebView {
        if let existing = terminalView { return existing }
        let palette: TerminalPalette = kind == .quick ? .quickLight : .workspaceDark
        let view = TerminalWebView(frame: .zero, palette: palette)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onUserInput = { [weak self] data in self?.pty?.write(data) }
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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if kind == .quick {
            for (key, value) in QuickSessionPolicy.environment(for: quickLaunch ?? .blank) {
                env[key] = value
            }
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
            quickLaunch: quickLaunch
        )

        let pty = PTYProcess()
        let view = terminalView
        pty.onOutput = { [weak view] data in view?.feed(data) }   // feed 내부에서 메인 큐 배칭
        pty.onExit = { [weak self] _ in
            DispatchQueue.main.async { self?.isRunning = false }
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
        updateQuickTitle(
            titlesBySessionId: QuickConversationScanner.shared.aiTitlesBySessionId
        )
        QuickConversationScanner.shared.rescan()
    }

    func updateQuickTitle(titlesBySessionId: [String: String]) {
        guard kind == .quick,
              let quickSessionId,
              let title = titlesBySessionId[quickSessionId] else { return }
        name = title
    }

    /// 죽은 탭 재시작 (프로세스 종료·시작 실패 후 재시도)
    func restartIfDead() {
        guard started, pty?.isRunning != true else { return }
        pty?.terminate()
        pty = nil
        startError = nil
        startPTY()
    }

    /// WKWebView 프로세스 크래시: 페이지 리로드 + PTY 재시작.
    /// tmux 세션은 서버에 살아있으므로 재attach로 무손실 복구된다 (스펙 §7).
    private func recoverFromCrash() {
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
        quickIdentityTimer?.invalidate()
        quickIdentityTimer = nil
        quickTitleCancellable = nil
        pty?.terminate(force: force)
        pty = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
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
        quickLaunch: QuickLaunch? = nil
    ) -> [String] {
        if kind == .quick {
            return ["-lc", QuickSessionPolicy.launchCommand(for: quickLaunch ?? .blank)]
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
                  tmuxSessionName: snapshot.tmuxSessionName)
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, kind: kind, name: name,
                    workingDirectory: workingDirectory,
                    tmuxSessionName: tmuxSessionName)
    }
}
