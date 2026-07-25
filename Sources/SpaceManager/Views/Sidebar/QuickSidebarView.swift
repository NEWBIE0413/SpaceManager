import SwiftUI

/// 헤르메스 창의 최소 사이드바. 워크스페이스·파일 계층 없이 q-N 대화만 소유한다.
struct QuickSidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "QUICK") {
                Button {
                    appState.addQuickSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("새 Claude 대화")
            }

            if appState.sessions.isEmpty {
                Text("새 대화를 시작하세요")
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

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
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
