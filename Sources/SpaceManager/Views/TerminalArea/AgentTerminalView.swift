import SwiftUI
import AppKit

/// Terminal view for a single session
struct AgentTerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let error = session.startError {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(.secondary)
                Button("다시 시도") {
                    session.restartIfDead()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SessionTerminalWrapper(session: session)
        }
    }
}

/// 세션 소유 터미널 뷰를 SwiftUI에 안전하게 호스팅한다.
///
/// makeNSView는 매번 새 컨테이너(TerminalHostView)를 반환한다 — NavigationSplitView가
/// macOS에서 디테일 계층을 중복 인스턴스화해 유지하기 때문에, 세션의 단일 NSView를
/// 직접 반환하면 계층들끼리 뷰를 뺏고 결국 화면 밖 계층이 가져가 공백이 된다.
/// 대신 "윈도우에 실제로 붙어 있는" 컨테이너만 터미널 뷰를 인수(claim)한다.
struct SessionTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.terminal = session.getOrCreateTerminal()
        host.attachIfNeeded()
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.terminal = session.getOrCreateTerminal()
        host.attachIfNeeded()
        // 포커스는 실제 화면에 있는 계층에서만
        if host.window != nil {
            session.focusTerminal()
        }
    }
}

/// 터미널 뷰를 담는 컨테이너. 윈도우에 붙은 컨테이너만 터미널을 소유한다.
final class TerminalHostView: NSView {
    weak var terminal: TerminalWebView?

    func attachIfNeeded() {
        guard let terminal, window != nil else { return }
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
    }
}
