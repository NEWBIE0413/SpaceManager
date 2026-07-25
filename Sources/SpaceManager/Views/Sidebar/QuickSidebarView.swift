import SwiftUI

/// 헤르메스 창의 최소 사이드바. 워크스페이스·파일 계층 없이 q-N 대화만 소유한다.
struct QuickSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var recentScanner = QuickConversationScanner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "새로 생성") {
                Button {
                    appState.showQuickHome()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("새 Claude 대화")
            }

            Button {
                appState.showQuickHome()
            } label: {
                Label("새 대화", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Sidebar.rowVerticalPadding)
                    .padding(.horizontal, Sidebar.rowHorizontalPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            SidebarSectionHeader(title: "열린 대화") {
                EmptyView()
            }

            Group {
                if appState.sessions.isEmpty {
                    Text("열린 대화가 없습니다")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(appState.sessions) { session in
                                QuickSessionRow(
                                    session: session,
                                    isSelected: appState.selectedSession?.id == session.id,
                                    onSelect: { appState.selectSession(session) },
                                    onClose: { appState.removeQuickSession(session) }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .frame(maxHeight: 220)

            SidebarSectionHeader(title: "최근 항목") {
                Button {
                    recentScanner.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("최근 대화 새로고침")
            }

            if recentScanner.conversations.isEmpty {
                Text("최근 대화가 없습니다")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(recentScanner.conversations) { conversation in
                            QuickRecentConversationRow(
                                conversation: conversation,
                                onResume: {
                                    appState.resumeQuickConversation(sessionId: conversation.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            recentScanner.start()
            recentScanner.rescan()
        }
    }
}

private struct QuickSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: Sidebar.iconSize))
                .foregroundColor(.secondary)
                .frame(width: Sidebar.iconFrame)

            Text(session.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.primary)

            Spacer(minLength: 0)

            Circle()
                .fill(session.isRunning ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("대화 종료")
        }
        .padding(.vertical, Sidebar.rowVerticalPadding)
        .padding(.horizontal, Sidebar.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                .fill(isSelected
                      ? Color.primary.opacity(0.08)
                      : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

private struct QuickRecentConversationRow: View {
    let conversation: QuickConversation
    let onResume: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: Sidebar.iconSize))
                .foregroundColor(.secondary)
                .frame(width: Sidebar.iconFrame)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(relativeTime(conversation.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Sidebar.rowVerticalPadding)
        .padding(.horizontal, Sidebar.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onResume)
        .help("이 대화 재개")
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }
}
