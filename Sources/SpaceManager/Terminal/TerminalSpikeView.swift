import SwiftUI

/// SM_SPIKE=1 환경변수로 실행 시 앱 대신 뜨는 검증용 단일 터미널.
/// 홈 디렉토리에서 sm-spike라는 tmux 세션에 attach한다.
struct TerminalSpikeView: NSViewRepresentable {
    final class Holder {
        let pty = PTYProcess()
        let view = TerminalWebView(frame: .zero)
        var started = false
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> TerminalWebView {
        let holder = context.coordinator
        let view = holder.view
        let pty = holder.pty

        view.onUserInput = { pty.write($0) }
        view.onResize = { cols, rows in pty.resize(cols: cols, rows: rows) }
        pty.onOutput = { [weak view] data in view?.feed(data) }
        view.onReady = {
            guard !holder.started else { return }
            holder.started = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            let script = "if tmux has-session -t sm-spike 2>/dev/null; then exec tmux attach-session -t sm-spike; else exec tmux new-session -s sm-spike; fi"
            try? pty.start(
                executable: shell,
                execName: "-" + (shell as NSString).lastPathComponent,
                arguments: ["-lc", script],
                environment: env,
                workingDirectory: NSHomeDirectory(),
                cols: 80, rows: 24
            )
        }
        return view
    }

    func updateNSView(_ nsView: TerminalWebView, context: Context) {}
}
