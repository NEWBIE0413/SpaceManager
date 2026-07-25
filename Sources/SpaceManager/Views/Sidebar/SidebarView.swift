import SwiftUI

/// Left sidebar containing workspaces and projects.
/// 라이트 모드에서도 딥 다크를 유지한다 — 아일랜드의 "완전 다크"를 패널로 연장한
/// 디자인 결정. 컬러스킴을 다크로 고정하면 .primary/.secondary/선택 배경이 전부
/// 다크 기준으로 풀리므로 개별 색을 손볼 필요가 없다.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    private var isDarkNow: Bool {
        switch appState.preferredAppearance {
        case "light": return false
        case "dark": return true
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspaces section — 고정 높이 + 자체 스크롤 (워크스페이스가 많아도 영역 불변)
            ScrollView {
                WorkspaceListView()
            }
            .frame(height: 320)

            Divider()
                .padding(.vertical, 8)

            // Projects section (for selected workspace)
            ProjectListView()

            Spacer()

            // Theme toggle at bottom
            HStack {
                Button {
                    appState.setAppearance(isDarkNow ? "light" : "dark")
                } label: {
                    Image(systemName: isDarkNow ? "sun.max" : "moon")
                }
                .buttonStyle(.plain)
                .help(isDarkNow ? "라이트 모드로 전환" : "다크 모드로 전환")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
        .background(BehindWindowGlassSurface(role: .workspaceSidebar))
        .environment(\.colorScheme, .dark)
    }
}
