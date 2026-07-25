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
                workingDirectory: QuickSessionPolicy.workingDirectory
            ),
            ["-lc", "exec ccv -y"]
        )
    }

    func testQuickPromptUsesEnvironmentInsteadOfShellInterpolation() {
        let prompt = #"따옴표 "와" $(touch /tmp/nope); 한글"#
        let launch = QuickLaunch.initialPrompt(prompt)
        XCTAssertEqual(
            TerminalSession.launchArguments(
                kind: .quick,
                tmuxSessionName: nil,
                workingDirectory: QuickSessionPolicy.workingDirectory,
                quickLaunch: launch
            ),
            ["-lc", #"exec ccv -y "$SM_INITIAL_PROMPT""#]
        )
        XCTAssertEqual(
            QuickSessionPolicy.environment(for: launch)["SM_INITIAL_PROMPT"],
            prompt
        )
        XCTAssertFalse(QuickSessionPolicy.launchCommand(for: launch).contains("touch"))
        XCTAssertTrue(QuickSessionPolicy.workingDirectory.hasSuffix("/cld"))
    }

    func testQuickResumeUsesEnvironmentAndCcvResumeMode() {
        let sessionId = "aeb62b66-9b9f-4286-822d-d6b25ece8978"
        let launch = QuickLaunch.resume(sessionId: sessionId)
        XCTAssertEqual(
            TerminalSession.launchArguments(
                kind: .quick,
                tmuxSessionName: nil,
                workingDirectory: QuickSessionPolicy.workingDirectory,
                quickLaunch: launch
            ),
            ["-lc", #"exec ccv -ry "$SM_RESUME_SESSION_ID""#]
        )
        XCTAssertEqual(
            QuickSessionPolicy.environment(for: launch)["SM_RESUME_SESSION_ID"],
            sessionId
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
            workingDirectory: QuickSessionPolicy.workingDirectory
        )
        XCTAssertNil(session.tmuxSessionName)
        session.cleanup() // 시작 전에도 즉시·무해하게 종료 가능
    }
}
