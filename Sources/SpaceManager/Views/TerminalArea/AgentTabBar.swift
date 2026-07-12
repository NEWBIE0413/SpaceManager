import SwiftUI
import UniformTypeIdentifiers

/// Tab bar for switching between agent sessions
struct AgentTabBar: View {
    @EnvironmentObject var appState: AppState
    @State private var draggingSession: TerminalSession?

    var body: some View {
        HStack(spacing: 0) {
            // Agent tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.sessions) { session in
                        AgentTab(
                            session: session,
                            isSelected: appState.selectedSession?.id == session.id
                        )
                        .onDrag {
                            draggingSession = session
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: AgentTabDropDelegate(
                                target: session,
                                sessions: $appState.sessions,
                                dragging: $draggingSession
                            ) { source, destination in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    appState.moveSession(from: source, to: destination)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            // Add agent button
            Button {
                appState.addShellTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("New Terminal Tab")
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AgentTabDropDelegate: DropDelegate {
    let target: TerminalSession
    @Binding var sessions: [TerminalSession]
    @Binding var dragging: TerminalSession?
    let moveAction: (_ source: Int, _ destination: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        guard let sourceIndex = sessions.firstIndex(of: dragging),
              let targetIndex = sessions.firstIndex(of: target) else { return }

        let destinationIndex = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        moveAction(sourceIndex, destinationIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Single agent tab
struct AgentTab: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    let isSelected: Bool

    @State private var isHovering = false

    private var dotColor: Color {
        if isSelected {
            return session.isRunning ? .green : .gray
        }
        return session.isRunning ? .green.opacity(0.4) : .gray.opacity(0.4)
    }

    private var textColor: Color {
        if isSelected { return .warmPink }
        return .primary.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(session.name)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(textColor)
                .lineLimit(1)

            if isHovering || isSelected {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.removeSession(session)
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
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color(nsColor: .controlBackgroundColor)
                      : Color(nsColor: .windowBackgroundColor).opacity(isHovering ? 0.5 : 0))
        )
        .frame(height: 38)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.selectSession(session)
            }
        }
    }
}
