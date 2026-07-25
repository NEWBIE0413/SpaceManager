import XCTest
@testable import SpaceManager

final class QuickSessionTests: XCTestCase {
    func testQuickSessionUsesFirstAvailableNumberAndDirectClaudePTY() {
        XCTAssertEqual(
            QuickSessionPolicy.nextName(usedNames: ["q-1", "q-2", "project"]),
            "q-3"
        )
        XCTAssertEqual(
            TerminalSession.launchArguments(
                kind: .quick,
                tmuxSessionName: nil,
                workingDirectory: NSHomeDirectory()
            ),
            ["-lc", "exec ccv -y"]
        )
    }

    func testQuickCloseHasNoPersistentTabsOrTmuxIdentity() throws {
        let state = WindowState(
            id: UUID(),
            kind: .quick,
            selectedWorkspaceId: nil,
            workspaceTabs: [],
            appearance: "light"
        )
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("quickTabs"))

        let session = TerminalSession(
            kind: .quick,
            name: "q-1",
            workingDirectory: NSHomeDirectory()
        )
        XCTAssertNil(session.tmuxSessionName)
        session.cleanup() // 시작 전에도 즉시·무해하게 종료 가능
    }
}
