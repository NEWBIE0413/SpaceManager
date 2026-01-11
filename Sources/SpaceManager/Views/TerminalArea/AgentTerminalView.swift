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
        SessionTerminalWrapper(
            session: session,
            isSelected: isSelected,
            focusMode: appState.agentFocusMode
        )
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
    let focusMode: AgentFocusMode

    func makeNSView(context: Context) -> ManagedTerminalView {
        // Get the session's terminal (creates if needed)
        let terminal = session.getOrCreateTerminal()
        terminal.sessionId = session.id
        terminal.setHoverFocusEnabled(focusMode == .hover)

        // Start the terminal process if not already started
        session.startTerminalIfNeeded()

        return terminal
    }

    func updateNSView(_ nsView: ManagedTerminalView, context: Context) {
        nsView.sessionId = session.id
        nsView.setHoverFocusEnabled(focusMode == .hover)
    }
}
