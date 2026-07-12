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
        XCTAssertTrue(s.contains("exec tmux new-session -s"))
    }

    func testWorkspaceEffectiveSessionName() {
        var ws = Workspace(rootPath: "/tmp/My.Project")
        XCTAssertEqual(ws.effectiveTmuxSessionName, "My-Project")
        ws.tmuxSessionName = "legacy-session"
        XCTAssertEqual(ws.effectiveTmuxSessionName, "legacy-session")
    }
}
