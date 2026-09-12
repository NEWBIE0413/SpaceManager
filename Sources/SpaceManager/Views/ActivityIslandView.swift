import SwiftUI
import AppKit

/// Give the island its own native compositing surface above WebKit. A plain
/// SwiftUI overlay can be covered by WebKit's redraw after the terminal resizes.
struct FloatingActivityIsland: NSViewRepresentable {
    let scanner: RecentActivityScanner
    let hover: IslandHoverState
    let appState: AppState

    func makeNSView(context: Context) -> NSHostingView<IslandContents> {
        let view = NSHostingView(rootView: contents)
        view.wantsLayer = true
        view.layer?.zPosition = 1
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }

    func updateNSView(_ view: NSHostingView<IslandContents>, context: Context) {
        view.rootView = contents
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<IslandContents>, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    private var contents: IslandContents {
        IslandContents(scanner: scanner, hover: hover, appState: appState)
    }
}

struct IslandContents: View {
    let scanner: RecentActivityScanner
    let hover: IslandHoverState
    let appState: AppState

    var body: some View {
        VStack(spacing: 6) {
            IslandPillView(scanner: scanner, hover: hover)
            IslandPanelView(scanner: scanner, hover: hover)
        }
        .fixedSize()
        .environmentObject(appState)
    }
}

/// 타이틀바의 다이내믹 아일랜드 — 최근 1시간 내 대화가 오간 Claude 세션들.
///
/// 목적은 상황 인지다: "아 내가 지금 이 작업들을 돌리고 있었지"가 한눈에 들어오게.
/// 접힌 필은 작업영역 위에 떠 있고, 호버하면 그 아래로 패널이
/// 내려온다. 활동이 없으면 필 자체가 사라진다 — 빈 껍데기가 떠 있으면 정보가
/// 아니라 장식이 된다.
///
/// 필과 패널 사이에서도 호버 상태가 이어지도록
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

/// 작업영역 상단에 겹쳐 뜨는 Dynamic Island pill
struct IslandPillView: View {
    @ObservedObject var scanner: RecentActivityScanner
    @ObservedObject var hover: IslandHoverState

    var body: some View {
        Group {
            if !scanner.sessions.isEmpty {
                Text(compactLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 30)
                .background(Color(red: 0.045, green: 0.052, blue: 0.064))
                .clipShape(Capsule(style: .continuous))
                .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 4)
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

/// 필 아래로 내려오는 확장 패널. 작업영역의 크기를 바꾸지 않는 오버레이.
struct IslandPanelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var scanner: RecentActivityScanner
    @ObservedObject var hover: IslandHoverState
    @ObservedObject private var windowRegistry = WorkspaceWindowRegistry.shared

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
                            canJump: windowRegistry.canJump(to: session.cwd, preferredState: appState),
                            onJump: {
                                if windowRegistry.jump(to: session.cwd, preferredState: appState) {
                                    hover.setPanel(false)
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 6)

                    Spacer().frame(height: 8)
                }
                .frame(width: 340)
                .background(Color(red: 0.045, green: 0.052, blue: 0.064))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
                .onHover { hover.setPanel($0) }
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: hover.isExpanded)
        .animation(.easeInOut(duration: 0.2), value: scanner.sessions)
    }

}

private struct IslandSessionRow: View {
    let session: RecentAgentSession
    let canJump: Bool
    let onJump: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                    if let host = session.host {
                        // 원격 머신에서 도는 세션 — 사이드바의 원격 배지와 같은 표식
                        Text("@\(host)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }

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

            // 앱의 어느 창이든 해당 워크스페이스를 소유할 때 점프 가능 표시
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.35))
                .opacity(canJump && isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering && canJump ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if canJump { onJump() } }
        .help(session.cwd)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "방금" }
        return "\(seconds / 60)분 전"
    }
}
