import SwiftUI

/// Tab bar for switching between agent sessions
struct AgentTabBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Agent tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.agentSessions) { session in
                        AgentTab(
                            session: session,
                            isSelected: appState.selectedAgentSession?.id == session.id
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // Add agent button
            Button {
                appState.addAgentSession()
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help("New Agent Tab (auto-splits)")
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Single agent tab
struct AgentTab: View {
    @EnvironmentObject var appState: AppState
    let session: AgentSession
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Text(session.name)
                .font(.caption)
                .lineLimit(1)

            if isHovering && appState.agentSessions.count > 1 {
                Button {
                    appState.removeAgentSession(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovering ? Color.gray.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            appState.selectAgentSession(session)
        }
    }
}
