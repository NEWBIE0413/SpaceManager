import XCTest
@testable import SpaceManager

final class StorageRoundtripTests: XCTestCase {
    func testWindowStateRoundtrip() throws {
        let tab = TabSnapshot(id: UUID(), kind: .tmuxMain, name: "work",
                              workingDirectory: "/tmp/work", tmuxSessionName: "work")
        let shell = TabSnapshot(id: UUID(), kind: .shell, name: "zsh",
                                workingDirectory: "/tmp/work", tmuxSessionName: nil)
        let wsId = UUID()
        let state = WindowState(
            id: UUID(),
            selectedWorkspaceId: wsId,
            workspaceTabs: [WorkspaceTabsState(workspaceId: wsId, selectedTabId: tab.id, tabs: [tab, shell])]
        )
        let data = try JSONEncoder().encode([state])
        let decoded = try JSONDecoder().decode([WindowState].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, state.id)
        XCTAssertEqual(decoded[0].workspaceTabs[0].tabs.map(\.kind), [.tmuxMain, .shell])
        XCTAssertEqual(decoded[0].workspaceTabs[0].selectedTabId, tab.id)
    }

    func testWorkspaceDecodesLegacyJSONWithoutNewFields() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","rootPath":"/tmp/x","additionalProjects":[],
         "orchestratorEnabled":true,
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ws = try decoder.decode(Workspace.self, from: Data(legacy.utf8))
        XCTAssertEqual(ws.name, "x")
        XCTAssertNil(ws.tmuxSessionName)   // 구 파일 호환: 새 필드 없어도 로드됨
    }

    func testWindowStateDecodesLegacyJSONWithoutWorkspacesField() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","selectedWorkspaceId":null,"workspaceTabs":[]}
        """
        let state = try JSONDecoder().decode(WindowState.self, from: Data(legacy.utf8))
        XCTAssertNil(state.workspaces)   // 레거시 상태 → 전역 목록 폴백 트리거
    }
}
