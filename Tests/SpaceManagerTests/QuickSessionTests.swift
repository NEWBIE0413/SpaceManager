import XCTest
@testable import SpaceManager

final class QuickSessionTests: XCTestCase {
    func testQuickSessionUsesFriendlyInitialNameAndDirectClaudePTY() {
        XCTAssertEqual(QuickSessionPolicy.initialSessionName, "새 대화 세션")
        XCTAssertEqual(
            TerminalSession.launchArguments(
                kind: .quick,
                tmuxSessionName: nil,
                workingDirectory: QuickSessionPolicy.workingDirectory
            ),
            ["-lc", #"exec "$SM_CCV" -y --model "$SM_MODEL" --effort "$SM_EFFORT""#]
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
            ["-lc", #"exec "$SM_CCV" -y --model "$SM_MODEL" --effort "$SM_EFFORT" "$SM_INITIAL_PROMPT""#]
        )
        XCTAssertEqual(
            QuickSessionPolicy.environment(for: launch)["SM_INITIAL_PROMPT"],
            prompt
        )
        XCTAssertEqual(QuickSessionPolicy.environment(for: launch)["SM_MODEL"], "claude-sonnet-5")
        XCTAssertEqual(QuickSessionPolicy.environment(for: launch)["SM_EFFORT"], "high")
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
            ["-lc", #"exec "$SM_CCV" -ry "$SM_RESUME_SESSION_ID" --model "$SM_MODEL" --effort "$SM_EFFORT""#]
        )
        XCTAssertEqual(
            QuickSessionPolicy.environment(for: launch)["SM_RESUME_SESSION_ID"],
            sessionId
        )
    }

    func testQuickProxyEnvironmentIsOnlyInjectedForProxySessions() {
        let inherited = [
            "PATH": "/usr/bin",
            "ANTHROPIC_BASE_URL": "http://stale.example",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
        ]
        let direct = QuickSessionPolicy.applyingEnvironment(
            inherited,
            launch: .blank,
            configuration: .default
        )
        XCTAssertNil(direct["ANTHROPIC_BASE_URL"])
        XCTAssertNil(direct["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"])
        XCTAssertEqual(direct["SM_CCV"], QuickSessionPolicy.ccvExecutablePath)
        XCTAssertTrue(direct["PATH"]?.hasPrefix(NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:") == true)
        XCTAssertTrue(QuickSessionPolicy.ccvExecutablePath.hasPrefix("/"))

        let proxy = QuickSessionPolicy.applyingEnvironment(
            inherited,
            launch: .blank,
            configuration: QuickSessionConfiguration(
                modelID: "claude-codex-gpt-5.6-terra",
                effort: .xhigh,
                proxyEnabled: false
            )
        )
        XCTAssertEqual(proxy["ANTHROPIC_BASE_URL"], "http://127.0.0.1:4141")
        XCTAssertEqual(proxy["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "1")
        XCTAssertEqual(proxy["SM_MODEL"], "claude-codex-gpt-5.6-terra")
        XCTAssertEqual(proxy["SM_EFFORT"], "xhigh")
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

    func testSidebarNewConversationShowsComposerWithoutClosingOpenTabs() {
        let state = AppState(windowKind: .quick)
        let session = TerminalSession(
            kind: .quick,
            name: "q-1",
            workingDirectory: QuickSessionPolicy.workingDirectory
        )
        state.sessions = [session]
        state.selectedSession = session

        state.showQuickHome()

        XCTAssertNil(state.selectedSession)
        XCTAssertEqual(state.sessions.map(\.id), [session.id])
        session.cleanup()
    }

    func testRecentConversationSelectsAlreadyOpenResumeTab() {
        let sessionId = UUID().uuidString.lowercased()
        let state = AppState(windowKind: .quick)
        let other = TerminalSession(
            kind: .quick,
            name: QuickSessionPolicy.initialSessionName,
            workingDirectory: QuickSessionPolicy.workingDirectory
        )
        let resumed = TerminalSession(
            kind: .quick,
            name: "Existing title",
            workingDirectory: QuickSessionPolicy.workingDirectory,
            quickLaunch: .resume(sessionId: sessionId)
        )
        state.sessions = [other, resumed]
        state.selectedSession = other

        state.resumeQuickConversation(sessionId: sessionId)

        XCTAssertIdentical(state.selectedSession, resumed)
        XCTAssertEqual(state.sessions.count, 2)
    }

    func testUnresolvedBlankTabDoesNotClaimRecentConversationIdentity() {
        let blank = TerminalSession(
            kind: .quick,
            name: QuickSessionPolicy.initialSessionName,
            workingDirectory: QuickSessionPolicy.workingDirectory
        )

        XCTAssertFalse(blank.matchesQuickConversation(sessionId: UUID().uuidString))
    }
}
