import SwiftUI

/// Tab bar for switching between agent sessions
struct AgentTabBar: View {
    @EnvironmentObject var appState: AppState
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            // Agent tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.agentSessions) { session in
                        AgentTab(
                            session: session,
                            isSelected: appState.selectedAgentSession?.id == session.id,
                            animation: animation
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            // Add agent button
            Button {
                appState.addAgentSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("New Agent Tab (auto-splits)")
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .bottom
        )
    }
}

/// Single agent tab
struct AgentTab: View {
    @EnvironmentObject var appState: AppState
    let session: AgentSession
    let isSelected: Bool
    var animation: Namespace.ID

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab Background
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .matchedGeometryEffect(id: "tab_background", in: animation)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            // Tab Content
            HStack(spacing: 8) {
                // Status Dot
                Circle()
                    .fill(session.isRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                    .shadow(color: session.isRunning ? Color.green.opacity(0.5) : .clear, radius: 2)

                Text(session.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                // Close Button
                if isHovering || isSelected {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.removeAgentSession(session)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0.5)
                } else {
                    Spacer().frame(width: 16)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34) // Slightly smaller than container to allow margin
            .padding(.bottom, 2) // Lift up slightly

            // Indicator Line
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .matchedGeometryEffect(id: "tab_indicator", in: animation)
            }
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.selectAgentSession(session)
            }
        }
    }
}


