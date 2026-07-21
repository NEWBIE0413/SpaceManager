import Foundation
import SwiftUI

enum TabKind: String, Codable {
    case tmuxMain    // 워크스페이스 고정 탭 — 워크스페이스 tmux 세션에 attach
    case shell       // 순수 셸 탭 — 앱 재시작 시 새 셸로 시작 (복구 없음, 명시적 한계)
    case tmuxExtra   // 추가 tmux 탭 — <세션명>-N, 재부팅 후에도 복구됨
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

    private(set) var terminalView: TerminalWebView?
    private var pty: PTYProcess?
    private var started = false

    init(id: UUID = UUID(), kind: TabKind, name: String,
         workingDirectory: String, tmuxSessionName: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
    }

    func getOrCreateTerminal() -> TerminalWebView {
        if let existing = terminalView { return existing }
        let view = TerminalWebView(frame: .zero)
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

    private func startPTY() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        let startDir = FileManager.default.fileExists(atPath: workingDirectory)
            ? workingDirectory : NSHomeDirectory()
        let arguments: [String]
        if let sessionName = tmuxSessionName {
            arguments = ["-lc", TmuxBootstrap.startupScript(sessionName: sessionName, workingDirectory: startDir)]
        } else {
            arguments = []   // 순수 인터랙티브 로그인 셸
        }

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
        } catch {
            startError = "터미널 시작 실패: \(error)"
            isRunning = false
        }
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

    func cleanup() {
        pty?.terminate()
        pty = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
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
