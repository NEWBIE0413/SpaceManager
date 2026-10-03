import XCTest
@testable import SpaceManager

/// `sm tabs <ws>`가 보여 준 탭은 선택 상태와 무관하게 다시 지목할 수 있어야 한다.
final class ControlTabTargetingTests: XCTestCase {
    private func tab(_ name: String) -> TerminalSession {
        TerminalSession(kind: .shell, name: name, workingDirectory: "/tmp")
    }

    func testTabsInUnselectedWorkspacesResolveByIdNameAndPrefix() throws {
        let a1 = tab("zsh"), a2 = tab("logs"), b1 = tab("zsh"), b2 = tab("build")
        let groups = [[a1, a2], [b1, b2]]

        let byId = try XCTUnwrap(ControlCommands.matchTab(b2.id.uuidString, in: groups))
        XCTAssertEqual(byId.group, 1)
        XCTAssertTrue(byId.session === b2)

        let byPrefix = try XCTUnwrap(ControlCommands.matchTab(String(b1.id.uuidString.prefix(8)), in: groups))
        XCTAssertTrue(byPrefix.session === b1)

        XCTAssertTrue(ControlCommands.matchTab("build", in: groups)?.session === b2)
        XCTAssertTrue(ControlCommands.matchTab("zsh", in: groups)?.session === a1, "같은 이름이면 보이는 탭이 이긴다")
        XCTAssertTrue(ControlCommands.matchTab("1", in: groups)?.session === a2, "인덱스는 보이는 목록 기준")
        XCTAssertNil(ControlCommands.matchTab("3", in: groups))
        XCTAssertNil(ControlCommands.matchTab("nope", in: groups))
    }

    func testClosingTabOfUnselectedWorkspaceKeepsCurrentSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirA = root.appendingPathComponent("a"), dirB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(requestedWindowStateId: UUID())
        XCTAssertNil(state.createWorkspace(rootPath: dirA.path, customName: "a-\(UUID().uuidString)"))
        let wsA = try XCTUnwrap(state.selectedWorkspace)
        state.addShellTab()
        let shellA = try XCTUnwrap(state.selectedSession)
        XCTAssertNil(state.createWorkspace(rootPath: dirB.path, customName: "b-\(UUID().uuidString)"))
        let wsB = try XCTUnwrap(state.selectedWorkspace)
        defer { state.deleteWorkspace(wsA); state.deleteWorkspace(wsB) }
        let selectedInB = state.selectedSession?.id

        XCTAssertTrue(state.sessions(for: wsA).contains { $0.id == shellA.id })
        state.removeSession(shellA)

        XCTAssertFalse(state.sessions(for: wsA).contains { $0.id == shellA.id })
        XCTAssertEqual(state.selectedWorkspace?.id, wsB.id)
        XCTAssertEqual(state.selectedSession?.id, selectedInB)
        state.selectWorkspace(wsA)
        XCTAssertFalse(state.sessions.contains { $0.id == shellA.id }, "닫힌 탭이 다시 방문할 때 되살아나면 안 된다")
    }
}
