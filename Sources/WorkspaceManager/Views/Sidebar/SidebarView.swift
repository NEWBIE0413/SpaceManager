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

            // Add project button
            if appState.selectedWorkspace != nil {
                Button {
                    appState.showAddProjectSheet = true
                } label: {
                    Label("Add Folder", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
