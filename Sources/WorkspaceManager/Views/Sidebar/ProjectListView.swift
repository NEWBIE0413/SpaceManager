import SwiftUI

/// List of projects in the selected workspace
struct ProjectListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROJECTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if let workspace = appState.selectedWorkspace {
                // Root project (always first)
                let rootProject = Project(path: workspace.rootPath)
                ProjectRow(
                    project: rootProject,
                    isSelected: appState.selectedProject?.path == rootProject.path,
                    isRoot: true
                )
                .onTapGesture {
                    appState.selectProject(rootProject)
                }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootProject.path)
                    }
                }

                // Additional projects
                ForEach(workspace.additionalProjects) { project in
                    ProjectRow(
                        project: project,
                        isSelected: appState.selectedProject?.id == project.id,
                        isRoot: false
                    )
                    .onTapGesture {
                        appState.selectProject(project)
                    }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            appState.removeProject(project)
                        }
                    }
                }
            } else {
                Text("Select a workspace")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Single project row
struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    var isRoot: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRoot ? "folder.fill" : "folder")
                .font(.caption)
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Text(project.name)
                .font(.callout)
                .fontWeight(isRoot ? .medium : .regular)
                .lineLimit(1)

            if isRoot {
                Text("(root)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !project.exists {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .help("Path not found")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .padding(.horizontal, 4)
        .help(project.path)
    }
}
