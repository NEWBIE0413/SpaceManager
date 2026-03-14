import SwiftUI

/// Left sidebar containing workspaces and projects
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspaces section
            WorkspaceListView()

            Divider()
                .padding(.vertical, 8)

            // Projects section (for selected workspace)
            ProjectListView()

            Spacer()
        }
        .frame(maxHeight: .infinity)
    }
}
