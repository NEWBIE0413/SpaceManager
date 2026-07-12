import SwiftUI

/// Right pane containing terminal tabs and the selected terminal
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            AgentTabBar()
            SingleTerminalView()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Single terminal view for the selected session
struct SingleTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.selectedSession {
            SessionContentView(session: session)
                .id(session.id)
        } else {
            VStack {
                Text("No terminal")
                    .foregroundColor(.secondary)
                Button("New Terminal") {
                    appState.addShellTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SessionContentView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        AgentTerminalView(session: session)
    }
}
