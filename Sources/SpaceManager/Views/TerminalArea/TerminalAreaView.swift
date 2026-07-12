import SwiftUI

/// Right pane containing terminal tabs and the selected terminal
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !TmuxBootstrap.isTmuxAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("tmux가 설치되어 있지 않아 셸 탭만 사용할 수 있습니다 — `brew install tmux` 후 재실행")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
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
