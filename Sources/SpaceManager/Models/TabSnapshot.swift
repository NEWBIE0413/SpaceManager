import Foundation

enum WindowKind: String, Codable, CaseIterable {
    case workspace
    case quick

    var sceneID: String {
        switch self {
        case .workspace: return "main"
        case .quick: return "quick"
        }
    }
}

/// 탭 하나의 영속 스냅샷 (window-states.json)
struct TabSnapshot: Codable, Identifiable {
    let id: UUID
    var kind: TabKind
    var name: String
    var workingDirectory: String
    var tmuxSessionName: String?
    /// nil이면 로컬. 구 JSON에는 없는 필드 — 기본값으로 로드된다.
    var remoteHost: String? = nil
}

/// 한 창에서 특정 워크스페이스에 열려 있던 탭 구성
struct WorkspaceTabsState: Codable {
    var workspaceId: UUID
    var selectedTabId: UUID?
    var tabs: [TabSnapshot]
}

/// AppKit 전역 화면 좌표계의 창 프레임. CGRect를 저장 형식에 직접 노출하지 않아
/// 레거시 JSON 호환성과 테스트를 단순하게 유지한다.
struct WindowFrameState: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// 창 하나의 전체 상태.
/// 워크스페이스 목록은 전역 공유가 아니라 창별 소유 — 창마다 독립된 작업 세트.
struct WindowState: Codable, Identifiable {
    let id: UUID
    /// nil이면 Quick 창 도입 전 상태 — workspace 창으로 복원한다.
    var kind: WindowKind? = nil
    var selectedWorkspaceId: UUID?
    var workspaces: [Workspace]? = nil   // nil이면 레거시(전역 목록) 상태 — 복원 시 1회 이관
    var workspaceTabs: [WorkspaceTabsState]
    /// 창별 라이트/다크 선택 ("light"/"dark"/"system"). nil이면 레거시 — 전역 기본값 사용
    var appearance: String? = nil
    /// 확대/전체화면 전의 일반 창 프레임. nil이면 구 버전 상태다.
    var frame: WindowFrameState? = nil
    /// optional로 두어 필드가 없던 구 JSON도 별도 migration 없이 읽는다.
    var isZoomed: Bool? = nil
    var isFullscreen: Bool? = nil

    var resolvedKind: WindowKind { kind ?? .workspace }
    var resolvedIsZoomed: Bool { isZoomed ?? false }
    var resolvedIsFullscreen: Bool { isFullscreen ?? false }
}
