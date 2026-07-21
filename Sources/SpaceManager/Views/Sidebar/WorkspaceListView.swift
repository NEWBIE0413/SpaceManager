import SwiftUI
import UniformTypeIdentifiers

/// List of workspaces in the sidebar
struct WorkspaceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHoveringHeader = false
    @State private var draggingWorkspace: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeader(title: "WORKSPACES") {
                Button {
                    appState.showNewWorkspaceSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isHoveringHeader ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help("New Workspace")
                .onHover { isHoveringHeader = $0 }
            }

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
                            let alert = NSAlert()
                            alert.messageText = "워크스페이스 이름"
                            alert.informativeText = "비워두면 폴더명으로 돌아갑니다."
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                            input.stringValue = workspace.customName ?? ""
                            input.placeholderString = workspace.name
                            alert.accessoryView = input
                            if alert.runModal() == .alertFirstButtonReturn {
                                appState.renameWorkspace(workspace, to: input.stringValue.isEmpty ? nil : input.stringValue)
                            }
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

    /// 메인 탭은 워크스페이스의 고정 앵커라 닫아도 다음 방문에 재생성된다 —
    /// 닫히는 척만 하는 ×를 보여주느니 처음부터 닫기 대상에서 제외한다.
    private var isClosable: Bool { session.kind != .tmuxMain }

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

            Spacer(minLength: 0)

            // 자리를 항상 확보하고 투명도로만 나타낸다 — 호버 때 요소가 끼어들면
            // 텍스트가 밀리며 목록이 출렁인다
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .opacity(isClosable && isHovering ? 1 : 0)
            .allowsHitTesting(isClosable && isHovering)
        }
        .padding(.vertical, 4)
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .background(Sidebar.rowBackground(isSelected: isSelected, isHovering: isHovering))
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
                .font(.system(size: Sidebar.iconSize))
                .foregroundColor(isSelected ? .warmPink.opacity(0.8) : .secondary)
                .frame(width: Sidebar.iconFrame)

            // 경로 부제는 선택된 행에만 — 호버로 행 높이가 변하면 목록 전체가 출렁인다.
            // 다른 행의 경로는 툴팁(.help)으로 확인.
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .warmPink : .primary.opacity(0.9))
                    .lineLimit(1)

                if isSelected {
                    Text(workspace.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            // 자리를 항상 확보하고 투명도로만 나타낸다 (호버 출렁임 방지)
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
            .opacity(isSelected || isHovering ? 1 : 0)
            .allowsHitTesting(isSelected || isHovering)
        }
        .padding(.vertical, Sidebar.rowVerticalPadding)
        .padding(.horizontal, Sidebar.rowHorizontalPadding)
        .background(Sidebar.rowBackground(isSelected: isSelected, isHovering: isHovering))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(workspace.rootPath)
    }
}
