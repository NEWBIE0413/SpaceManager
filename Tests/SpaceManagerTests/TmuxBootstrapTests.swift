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
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: true, coldBootAt: t0, now: t0.addingTimeInterval(200)), .warmAttach)
    }

    func testRoleRebirthWhenServerDiesAfterWindow() {
        let t0 = Date()
        XCTAssertEqual(TmuxBootstrap.startupRole(socketExists: false, coldBootAt: t0, now: t0.addingTimeInterval(200)), .coldBirther)
    }

    // MARK: - 콜드 부트 스크립트 v2 (순수 follower)

    // birther조차 서버를 즉시 깨우지 않는다 — 소켓이 안 나타날 때만 깨우는 폴백.
    // 외부 복구 파이프라인(continuum + 세션복구 에이전트)이 서버·세션의 주인이다.
    func testColdBirtherOnlyBirthsWhenSocketAbsent() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: true)
        XCTAssertTrue(s.contains("if [ ! -S \"$SOCK\" ]"), "소켓 부재 시에만 서버를 깨워야 한다")
        XCTAssertTrue(s.contains("tmux new-session -d -s __sm_boot"))
        XCTAssertTrue(s.contains("tmux kill-session -t __sm_boot"))
        XCTAssertTrue(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec tmux attach-session -t 'ws'"))
    }

    func testColdFollowerNeverTouchesBootSession() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: false)
        XCTAssertFalse(s.contains("__sm_boot"))
        XCTAssertTrue(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec tmux attach-session -t 'ws'"))
    }

    // 서버 대기는 tmux 프로세스를 만들지 않는 소켓 파일 폴링이어야 한다 —
    // 폴링 프로세스가 conf 로드 시점에 잡히면 continuum 가드가 오판한다
    func testColdBootWaitsOnSocketFileNotTmuxCommands() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: false)
        XCTAssertTrue(s.contains("while [ ! -S \"$SOCK\" ]"))
        XCTAssertFalse(s.contains("pgrep"), "restore.sh 프로세스 유무로 조기 탈출하던 휴리스틱은 제거됐다")
    }

    // 재부팅 직전 저장이 유실되면 last가 댕글링 — 최신 실존 저장본으로 자가치유해야
    // 복원 파이프라인이 살아난다 (2026-07-24 사고 원인 ①)
    func testColdBootHealsDanglingLastSymlink() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: true)
        XCTAssertTrue(s.contains("[ -L \"$RES/last\" ] && [ ! -e \"$RES/last\" ]"))
        XCTAssertTrue(s.contains("ln -sf"))
    }

    // 저장본에 있는 세션명은 복원이 채울 이름이다 — 앱이 선점 생성하면 레이아웃이
    // 유실되고 에이전트 주입 좌표가 어긋난다 (사고 원인 ②). awk로 저장본을 검사해
    // 있으면 오래(240폴), 없으면 짧게(20폴) 기다린 뒤에만 생성한다.
    func testColdBootWaitsLongerForSavedSessions() {
        let s = TmuxBootstrap.coldBootScript(sessionName: "ws", workingDirectory: "/tmp", birther: false)
        XCTAssertTrue(s.contains("awk -F'\\t' -v n='ws'"))
        XCTAssertTrue(s.contains("WAIT=240"))
        XCTAssertTrue(s.contains("WAIT=20"))
    }

    func testWorkspaceEffectiveSessionName() {
        var ws = Workspace(rootPath: "/tmp/My.Project")
        XCTAssertEqual(ws.effectiveTmuxSessionName, "My-Project")
        ws.tmuxSessionName = "legacy-session"
        XCTAssertEqual(ws.effectiveTmuxSessionName, "legacy-session")
    }
}
