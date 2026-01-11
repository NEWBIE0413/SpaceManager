import SwiftUI
import SwiftTerm

/// Right pane containing agent tabs and terminal
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Agent tab bar
            AgentTabBar()

            Divider()

            // Terminal content - auto-split when multiple agents
            if appState.agentSessions.count > 1 {
                SplitTerminalView()
            } else {
                SingleTerminalView()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Single terminal view for the selected agent
struct SingleTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.selectedAgentSession {
            SessionContentView(session: session)
        } else {
            VStack {
                Text("No agent session")
                    .foregroundColor(.secondary)
                Button("Create Agent") {
                    appState.addAgentSession()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// View that observes a single session and switches between launcher and terminal
struct SessionContentView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        ZStack {
            if session.hasLaunchedCommand {
                AgentTerminalView(session: session)
            } else {
                LauncherTUIView(session: session)
            }
        }
    }
}

/// Split view showing multiple terminals side by side with equal widths
struct SplitTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            let sessionCount = CGFloat(appState.agentSessions.count)
            let dividerCount = CGFloat(max(0, appState.agentSessions.count - 1))
            let dividerWidth: CGFloat = 1
            let sessionWidth = (geometry.size.width - dividerCount * dividerWidth) / sessionCount

            HStack(spacing: 0) {
                ForEach(Array(appState.agentSessions.enumerated()), id: \.element.id) { index, session in
                    SplitSessionView(
                        session: session,
                        width: sessionWidth
                    )

                    // Add divider between sessions (not after last one)
                    if index < appState.agentSessions.count - 1 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: dividerWidth)
                    }
                }
            }
        }
    }
}

/// Individual session view in split mode - observes session for state changes
struct SplitSessionView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var appState: AppState
    let width: CGFloat

    var isSelected: Bool {
        appState.selectedAgentSession?.id == session.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mini header
            HStack {
                Circle()
                    .fill(session.isRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(session.name)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                // Close button
                if appState.agentSessions.count > 1 {
                    Button {
                        appState.removeAgentSession(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            // Terminal or Launcher - uses SessionContentView which observes the session
            SessionContentView(session: session)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .frame(width: width)
        .onTapGesture {
            appState.selectAgentSession(session)
        }
        .onHover { hovering in
            if hovering, appState.agentFocusMode == .hover {
                appState.selectAgentSession(session)
            }
        }
    }
}
