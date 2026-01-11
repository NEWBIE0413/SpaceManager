import SwiftUI

/// List of workspaces in the sidebar
struct WorkspaceListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("WORKSPACES")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    appState.showNewWorkspaceSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("New Workspace")
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if appState.storage.workspaces.isEmpty {
                Text("No workspaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.storage.workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isSelected: appState.selectedWorkspace?.id == workspace.id
                    )
                    .onTapGesture {
                        appState.selectWorkspace(workspace)
                    }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.rootPath)
                        }
                        Button("Rename...") {
                            // TODO: Show rename dialog
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteWorkspace(workspace)
                        }
                    }
                }
            }
        }
    }
}

/// Single workspace row
struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(.caption)
                .foregroundColor(isSelected ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.callout)
                    .lineLimit(1)

                Text(workspace.rootPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if workspace.additionalProjects.count > 0 {
                Text("+\(workspace.additionalProjects.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .padding(.horizontal, 4)
        .help(workspace.rootPath)
    }
}
