import SwiftUI

/// 타이틀바의 다이내믹 아일랜드 — 최근 1시간 내 대화가 오간 Claude 세션들.
///
/// 목적은 상황 인지다: "아 내가 지금 이 작업들을 돌리고 있었지"가 한눈에 들어오게.
/// 접힌 필은 타이틀바 중앙(노치 자리)에 상주하고, 호버하면 타이틀바 아래로 패널이
/// 내려온다. 활동이 없으면 필 자체가 사라진다 — 빈 껍데기가 떠 있으면 정보가
/// 아니라 장식이 된다.
///
/// 필(툴바)과 패널(오버레이)은 다른 뷰 계층에 살기 때문에, 호버 상태를
/// IslandHoverState 하나로 모아 "필이나 패널 어느 쪽에라도 포인터가 있으면 펼침,
/// 둘 다 떠나면 잠깐의 유예 후 접힘"으로 판정한다 — 필→패널로 포인터가 건너가는
/// 사이에 접혀버리는 깜빡임을 막는 유예다.
final class IslandHoverState: ObservableObject {
    @Published var isExpanded = false
    private var pillHovering = false
    private var panelHovering = false

    func setPill(_ hovering: Bool) { pillHovering = hovering; update() }
    func setPanel(_ hovering: Bool) { panelHovering = hovering; update() }

    private func update() {
        if pillHovering || panelHovering {
            isExpanded = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.pillHovering, !self.panelHovering else { return }
            self.isExpanded = false
        }
    }
}

/// 타이틀바에 상주하는 접힌 필 (ToolbarItem placement: .principal)
struct IslandPillView: View {
    @ObservedObject var scanner: RecentActivityScanner
    @ObservedObject var hover: IslandHoverState
    @State private var pulse = false

    var body: some View {
        Group {
            if !scanner.sessions.isEmpty {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.warmPink)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 0.35 : 1)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }

                    Text(compactLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.panelDark.opacity(0.96))
                .clipShape(Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .onHover { hovering in
                    hover.setPill(hovering)
                    if hovering { scanner.rescan() }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: scanner.sessions.isEmpty)
    }

    private var compactLabel: String {
        // 같은 프로젝트의 세션 여러 개는 이름 하나로 접는다
        var seen = Set<String>()
        let unique = scanner.sessions.map(\.name).filter { seen.insert($0).inserted }
        let preview = unique.prefix(3).joined(separator: " · ")
        let rest = unique.count - min(unique.count, 3)
        return rest > 0 ? "\(preview) +\(rest)" : preview
    }
}

/// 필 호버 시 타이틀바 아래로 내려오는 확장 패널 (창 콘텐츠 상단 중앙 오버레이)
struct IslandPanelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var scanner: RecentActivityScanner
    @ObservedObject var hover: IslandHoverState

    var body: some View {
        Group {
            if hover.isExpanded && !scanner.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
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
                                hover.setPanel(false)
                            }
                        )
                    }
                    .padding(.horizontal, 6)

                    Spacer().frame(height: 8)
                }
                .frame(width: 340)
                .background(Color.panelDark.opacity(0.97))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                .onHover { hover.setPanel($0) }
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: hover.isExpanded)
        .animation(.easeInOut(duration: 0.2), value: scanner.sessions)
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
