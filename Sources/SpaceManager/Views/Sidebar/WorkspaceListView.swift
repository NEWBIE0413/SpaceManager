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

            if appState.workspaces.isEmpty {
                Text("No workspaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isSelected: appState.selectedWorkspace?.id == workspace.id,
                        onAddShellTab: { appState.selectWorkspace(workspace); appState.addShellTab() },
                        onAddTmuxTab: { appState.selectWorkspace(workspace); appState.addTmuxTab() }
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
                            workspaces: { appState.workspaces },
                            dragging: $draggingWorkspace
                        ) { source, destination in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appState.moveWorkspace(from: source, to: destination)
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

                    // 선택된 워크스페이스의 탭 폴더링 — 탭이 2개 이상일 때만 하위 목록 표시
                    if appState.selectedWorkspace?.id == workspace.id && appState.sessions.count > 1 {
                        ForEach(appState.sessions) { session in
                            WorkspaceTabRow(
                                session: session,
                                isSelected: appState.selectedSession?.id == session.id,
                                onSelect: { appState.selectSession(session) },
                                onClose: { appState.removeSession(session) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

/// 워크스페이스 하위 탭 행 (폴더링 목록의 항목)
struct WorkspaceTabRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isRunning
                      ? Color.green.opacity(isSelected ? 1 : 0.5)
                      : Color.gray.opacity(isSelected ? 1 : 0.5))
                .frame(width: 5, height: 5)

            Text(session.name)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .warmPink : .primary.opacity(0.7))
                .lineLimit(1)

            Spacer()

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.primary.opacity(0.06) : (isHovering ? Color.primary.opacity(0.03) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
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
    var onAddShellTab: (() -> Void)?
    var onAddTmuxTab: (() -> Void)?
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

            // 새 탭 메뉴 — 선택/호버 시 표시
            if isSelected || isHovering {
                Menu {
                    Button("셸 탭") { onAddShellTab?() }
                    if TmuxBootstrap.isTmuxAvailable {
                        Button("tmux 탭") { onAddTmuxTab?() }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("New Tab")
            }

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
