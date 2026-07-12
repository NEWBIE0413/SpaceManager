import SwiftUI

/// Left sidebar containing workspaces and projects
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

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
        }
        .frame(maxHeight: .infinity)
    }
}
