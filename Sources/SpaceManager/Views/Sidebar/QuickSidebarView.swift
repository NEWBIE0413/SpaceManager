import SwiftUI

/// 헤르메스 창의 최소 사이드바. 워크스페이스·파일 계층 없이 q-N 대화만 소유한다.
struct QuickSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var recentScanner = QuickConversationScanner.shared
    @State private var isHoveringNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                appState.showQuickHome()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: Sidebar.iconSize))
                        .foregroundColor(.primary)
                        .frame(width: Sidebar.iconFrame)
                    Text("새 대화")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Sidebar.rowVerticalPadding)
                .padding(.horizontal, Sidebar.rowHorizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                        .fill(isHoveringNew ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .onHover { isHoveringNew = $0 }

            if !appState.sessions.isEmpty {
                QuickSectionHeader(title: "열린 대화") {
                    EmptyView()
                }

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(appState.sessions) { session in
                            QuickSessionRow(
                                session: session,
                                isSelected: appState.selectedSession?.id == session.id,
                                onSelect: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                                        appState.selectSession(session)
                                    }
                                },
                                onClose: { appState.removeQuickSession(session) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 220)
            }

            QuickSectionHeader(title: "최근 항목") {
                Button {
                    recentScanner.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("최근 대화 새로고침")
            }

            Group {
                if recentScanner.conversations.isEmpty {
                    Text("최근 대화가 없습니다")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
        .background(BehindWindowGlassSurface(role: .quickSidebar))
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
                .font(.system(size: Sidebar.iconSize, weight: .medium))
                .foregroundColor(.secondary.opacity(0.9))
                .frame(width: Sidebar.iconFrame)

            Text(session.name)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(.primary)

            Spacer(minLength: 0)

            Circle()
                .fill(session.isRunning ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("대화 종료")
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.vertical, Sidebar.rowVerticalPadding)
        .padding(.horizontal, Sidebar.rowHorizontalPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
            } else if isHovering {
                RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
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
            Image(systemName: "bubble.left")
                .font(.system(size: Sidebar.iconSize, weight: .medium))
                .foregroundColor(.secondary.opacity(0.9))
                .frame(width: Sidebar.iconFrame)

            Text(conversation.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.95))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(relativeTime(conversation.modifiedAt))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.85))
                .monospacedDigit()
        }
        .padding(.vertical, Sidebar.rowVerticalPadding)
        .padding(.horizontal, Sidebar.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                onResume()
            }
        }
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
