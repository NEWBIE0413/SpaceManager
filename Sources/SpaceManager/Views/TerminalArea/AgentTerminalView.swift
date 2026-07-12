import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view for a single session.
/// Uses the terminal owned by the session to ensure persistence.
struct AgentTerminalView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        SessionTerminalWrapper(session: session)
    }
}

struct SessionTerminalWrapper: NSViewRepresentable {
    let session: AgentSession

    func makeNSView(context: Context) -> ManagedTerminalView {
        let terminal = session.getOrCreateTerminal()
        terminal.sessionId = session.id
        session.startTerminalIfNeeded()
        return terminal
    }

    func updateNSView(_ nsView: ManagedTerminalView, context: Context) {
        nsView.sessionId = session.id
        session.focusTerminal()
    }
}
