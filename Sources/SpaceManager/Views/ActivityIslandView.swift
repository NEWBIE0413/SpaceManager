import SwiftUI

/// 상단 중앙의 다이내믹 아일랜드 — 최근 1시간 내 대화가 오간 Claude 세션들.
///
/// 목적은 상황 인지다: "아 내가 지금 이 작업들을 돌리고 있었지"가 한눈에 들어오게.
/// 그래서 접힌 상태는 프로젝트 이름 미리보기까지만, 펼친 상태는 마지막 유저 메시지
/// 한 줄과 경과 시간까지 보여준다. 활동이 없으면 아일랜드 자체가 사라진다 —
/// 빈 껍데기가 떠 있으면 정보가 아니라 장식이 된다.
struct ActivityIslandView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var scanner = RecentActivityScanner()
    @State private var isExpanded = false
    @State private var pulse = false

    var body: some View {
        Group {
            if !scanner.sessions.isEmpty {
                island
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: scanner.sessions.isEmpty)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                compactContent
            }
        }
        // 아일랜드는 라이트/다크 무관하게 검정 — 애플 다이내믹 아일랜드의 정체성이자,
        // 터미널 위에 떠도 이질감이 없는 유일한 색이다
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 18 : 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 18 : 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .onHover { hovering in
            isExpanded = hovering
            if hovering { scanner.rescan() }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: scanner.sessions)
    }

    // MARK: - 접힌 상태

    private var compactContent: some View {
        HStack(spacing: 7) {
            activityDot

            Text(compactLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    private var compactLabel: String {
        let names = scanner.sessions.map(\.name)
        // 같은 프로젝트의 세션 여러 개는 이름 하나로 접는다
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        let preview = unique.prefix(3).joined(separator: " · ")
        let rest = unique.count - min(unique.count, 3)
        return rest > 0 ? "\(preview) +\(rest)" : preview
    }

    private var activityDot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }

    // MARK: - 펼친 상태

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                activityDot
                Text("최근 1시간")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text("\(scanner.sessions.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)

            ForEach(scanner.sessions) { session in
                IslandSessionRow(
                    session: session,
                    targetWorkspace: workspace(for: session),
                    onJump: { workspace in
                        appState.selectWorkspace(workspace)
                        isExpanded = false
                    }
                )
            }
            .padding(.horizontal, 6)

            Spacer().frame(height: 8)
        }
        .frame(width: 340)
    }

    /// 세션 cwd가 이 창의 어느 워크스페이스에 속하는지 (가장 깊은 루트 우선)
    private func workspace(for session: RecentClaudeSession) -> Workspace? {
        appState.workspaces
            .filter { session.cwd == $0.rootPath || session.cwd.hasPrefix($0.rootPath + "/") }
            .max { $0.rootPath.count < $1.rootPath.count }
    }
}

private struct IslandSessionRow: View {
    let session: RecentClaudeSession
    let targetWorkspace: Workspace?
    let onJump: (Workspace) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                if let snippet = session.snippet {
                    Text(snippet)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(relativeTime(session.lastActivity))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .monospacedDigit()

            // 이 창에 해당 워크스페이스가 있을 때만 점프 가능 표시
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.35))
                .opacity(targetWorkspace != nil && isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering && targetWorkspace != nil ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let workspace = targetWorkspace { onJump(workspace) }
        }
        .help(session.cwd)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "방금" }
        return "\(seconds / 60)분 전"
    }
}
