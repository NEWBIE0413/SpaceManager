import XCTest
@testable import SpaceManager

final class TmuxBootstrapTests: XCTestCase {
    func testSanitizeReplacesForbiddenChars() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("my.proj: v2"), "my-proj--v2")
    }

    func testSanitizeEmptyFallsBack() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("   "), "workspace")
    }

    func testSanitizeKeepsKorean() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("한글 이름"), "한글-이름")
    }

    func testScriptQuotesSingleQuotes() {
        let s = TmuxBootstrap.attachOrCreateScript(sessionName: "a'b", workingDirectory: "/tmp/it's")
        XCTAssertTrue(s.contains("'a'\"'\"'b'"))
        XCTAssertTrue(s.contains("exec tmux attach-session -t"))
        XCTAssertTrue(s.contains("tmux new-session -d -s"))
    }

    // 병렬 탭이 같은 세션을 동시에 만들 때 `exec new-session` 한쪽이 고아로 남던
    // 경쟁을 없애기 위해, 생성은 -d로 하고 최종 명령은 항상 attach여야 한다
    func testAttachOrCreateEndsWithAttach() {
        let s = TmuxBootstrap.attachOrCreateScript(sessionName: "ws", workingDirectory: "/tmp")
        XCTAssertTrue(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec tmux attach-session -t 'ws'"))
        XCTAssertFalse(s.contains("exec tmux new-session"))
    }

    // MARK: - 콜드 부트 역할 선택 (순수 함수)

    func testRoleWarmWhenServerSocketExists() {
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: true, coldBootAt: nil, now: Date()), .warmAttach)
    }

    func testRoleBirtherOnFirstColdStart() {
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: false, coldBootAt: nil, now: Date()), .coldBirther)
    }

    func testRoleFollowerInsideColdBootWindow() {
        let t0 = Date()
        // birther가 소켓을 이미 만든 뒤라도(socketExists: true) 가드 평가 창 안에서는 조용히 기다려야 한다
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: true, coldBootAt: t0, now: t0.addingTimeInterval(1)), .coldFollower)
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: false, coldBootAt: t0, now: t0.addingTimeInterval(5)), .coldFollower)
    }

    func testRoleBackToWarmAfterColdBootWindow() {
        let t0 = Date()
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: true, coldBootAt: t0, now: t0.addingTimeInterval(20)), .warmAttach)
    }

    func testRoleRebirthWhenServerDiesAfterWindow() {
        let t0 = Date()
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: false, coldBootAt: t0, now: t0.addingTimeInterval(20)), .coldBirther)
    }

    // MARK: - 콜드 부트 스크립트

    func testColdBirtherScriptBirthsAndCleansBootSession() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: true)
        XCTAssertTrue(s.contains("tmux new-session -d -s __sm_boot"))
        XCTAssertTrue(s.contains("tmux kill-session -t __sm_boot"))
        XCTAssertTrue(s.contains("sleep 4"))
        XCTAssertTrue(s.contains("tmux-resurrect/scripts/restore.sh"))
        XCTAssertTrue(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec tmux attach-session -t 'ws'"))
    }

    func testColdFollowerScriptStaysQuietAndNeverTouchesBootSession() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: false)
        XCTAssertFalse(s.contains("__sm_boot"))
        XCTAssertTrue(s.contains("sleep 4"))
        XCTAssertTrue(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec tmux attach-session -t 'ws'"))
    }

    func testWorkspaceEffectiveSessionName() {
        var ws = Workspace(rootPath: "/tmp/My.Project")
        XCTAssertEqual(ws.effectiveTmuxSessionName, "My-Project")
        ws.tmuxSessionName = "legacy-session"
        XCTAssertEqual(ws.effectiveTmuxSessionName, "legacy-session")
    }
}
