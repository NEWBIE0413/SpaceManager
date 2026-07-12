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

struct SessionTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalWebView {
        session.getOrCreateTerminal()
    }

    func updateNSView(_ nsView: TerminalWebView, context: Context) {
        session.focusTerminal()
    }
}
