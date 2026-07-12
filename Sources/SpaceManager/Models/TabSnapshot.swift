import Foundation

/// 탭 하나의 영속 스냅샷 (window-states.json)
struct TabSnapshot: Codable, Identifiable {
    let id: UUID
    var kind: TabKind
    var name: String
    var workingDirectory: String
    var tmuxSessionName: String?
}

/// 한 창에서 특정 워크스페이스에 열려 있던 탭 구성
struct WorkspaceTabsState: Codable {
    var workspaceId: UUID
    var selectedTabId: UUID?
    var tabs: [TabSnapshot]
}

/// 창 하나의 전체 상태
struct WindowState: Codable, Identifiable {
    let id: UUID
    var selectedWorkspaceId: UUID?
    var workspaceTabs: [WorkspaceTabsState]
}
