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

            // Add tab menu: 셸 탭 / tmux 탭 (스펙 §5)
            Menu {
                Button("셸 탭") { appState.addShellTab() }
                    .help("워크스페이스 루트에서 순수 zsh — 재시작 시 복구되지 않음")
                if TmuxBootstrap.isTmuxAvailable {
                    Button("tmux 탭") { appState.addTmuxTab() }
                        .help("별도 tmux 세션 — 재부팅 후에도 복구됨")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40)
            .help("New Tab")
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
