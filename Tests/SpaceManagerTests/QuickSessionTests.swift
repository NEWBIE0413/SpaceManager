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

extension QuickSessionTests {
    /// `ccv`는 이 저장소를 받은 사람에게 있을 이유가 없는 개인용 런처다.
    /// 없을 때 `claude`를 직접 부르는 길이 맞는 플래그를 내보내는지 —
    /// 이 기계에는 ccv가 있어서 그냥 두면 아무도 지나가지 않는 분기다.
    func testLaunchesWithoutTheCcvWrapper() {
        func command(_ launch: QuickLaunch) -> String {
            QuickSessionPolicy.launchCommand(for: launch, usesWrapper: false)
        }

        XCTAssertTrue(command(.blank).contains("--dangerously-skip-permissions"))
        XCTAssertFalse(command(.blank).contains(" -y "))

        let resumed = command(.resume(sessionId: "x"))
        XCTAssertTrue(resumed.contains("--resume \"$SM_RESUME_SESSION_ID\""))
        XCTAssertFalse(resumed.contains("-ry"))

        // 모델과 깊이는 양쪽 런처가 같은 이름으로 받는다.
        for launch: QuickLaunch in [.blank, .initialPrompt("hi"), .resume(sessionId: "x")] {
            XCTAssertTrue(command(launch).contains("--model \"$SM_MODEL\""), "\(launch)")
            XCTAssertTrue(command(launch).contains("--effort \"$SM_EFFORT\""), "\(launch)")
            // 승인 건너뛰기는 정확히 한 번.
            XCTAssertEqual(
                command(launch).components(separatedBy: "--dangerously-skip-permissions").count - 1, 1,
                "\(launch): \(command(launch))"
            )
        }
    }
}
