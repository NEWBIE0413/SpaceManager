import SwiftUI
import UniformTypeIdentifiers

/// List of workspaces in the sidebar
struct WorkspaceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHoveringHeader = false
    @State private var draggingWorkspace: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Section Header
            HStack {
                Text("WORKSPACES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.warmPinkMuted)

                Spacer()

                Button {
                    appState.showNewWorkspaceSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isHoveringHeader ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("New Workspace")
                .onHover { isHoveringHeader = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if appState.storage.workspaces.isEmpty {
                Text("No workspaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
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
                    .onDrag {
                        draggingWorkspace = workspace
                        return NSItemProvider(object: workspace.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: WorkspaceDropDelegate(
                            target: workspace,
                            workspaces: { appState.storage.workspaces },
                            dragging: $draggingWorkspace
                        ) { source, destination in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appState.storage.moveWorkspace(from: source, to: destination)
                            }
                        }
                    )
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.rootPath)
                        }
                        Button("Rename...") {
                            // TODO: Show rename dialog
                        }
                        Button("Edit tmux Session Name...") {
                            let alert = NSAlert()
                            alert.messageText = "tmux 세션명"
                            alert.informativeText = "비워두면 이름에서 자동 파생됩니다. 현재: \(workspace.effectiveTmuxSessionName)"
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                            input.stringValue = workspace.tmuxSessionName ?? ""
                            input.placeholderString = workspace.effectiveTmuxSessionName
                            alert.accessoryView = input
                            if alert.runModal() == .alertFirstButtonReturn {
                                appState.setTmuxSessionName(workspace, to: input.stringValue)
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteWorkspace(workspace)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    let target: Workspace
    let workspaces: () -> [Workspace]
    @Binding var dragging: Workspace?
    let moveAction: (_ source: Int, _ destination: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let current = workspaces()
        guard let sourceIndex = current.firstIndex(of: dragging),
              let targetIndex = current.firstIndex(of: target) else { return }

        let destinationIndex = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        moveAction(sourceIndex, destinationIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Single workspace row
struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .warmPink : .primary.opacity(0.9))
                    .lineLimit(1)

                if isSelected || isHovering {
                    Text(workspace.rootPath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if workspace.additionalProjects.count > 0 {
                Text("\(workspace.additionalProjects.count)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.08) : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(workspace.rootPath)
    }
}
