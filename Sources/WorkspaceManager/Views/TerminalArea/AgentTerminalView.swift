import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view for a single agent session
/// Uses the terminal owned by the session to ensure persistence
struct AgentTerminalView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var appState: AppState

    var isSelected: Bool {
        appState.selectedAgentSession?.id == session.id
    }

    var body: some View {
        SessionTerminalWrapper(session: session, isSelected: isSelected)
            .onReceive(NotificationCenter.default.publisher(for: .sendTerminalCommand)) { notification in
                if isSelected, let command = notification.userInfo?["command"] as? String {
                    session.terminalView?.send(txt: command + "\n")
                }
            }
    }
}

/// NSViewRepresentable that embeds the session's terminal directly
struct SessionTerminalWrapper: NSViewRepresentable {
    let session: AgentSession
    let isSelected: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Get the session's terminal (creates if needed)
        let terminal = session.getOrCreateTerminal()

        // Start the terminal process if not already started
        session.startTerminalIfNeeded()

        // Focus if selected
        if isSelected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                session.focusTerminal()
            }
        }

        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Focus terminal when it becomes selected
        if isSelected {
            session.focusTerminal()
        }
    }
}
