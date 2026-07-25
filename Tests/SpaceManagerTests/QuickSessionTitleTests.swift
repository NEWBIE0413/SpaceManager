import XCTest
import Combine
@testable import SpaceManager

final class QuickSessionTitleTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testSessionIdentityUsesPIDAndRejectsNonQuickCwd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let pid: pid_t = 42_424
        let sessionId = UUID().uuidString.lowercased()
        let record = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/tmp/cld","name":"do-not-use"}
        """
        try Data(record.utf8).write(
            to: directory.appendingPathComponent("\(pid).json")
        )

        XCTAssertEqual(
            QuickSessionTitleResolver.sessionId(
                processIdentifier: pid,
                sessionsDirectory: directory,
                expectedWorkingDirectory: "/tmp/cld"
            ),
            sessionId
        )
        XCTAssertNil(
            QuickSessionTitleResolver.sessionId(
                processIdentifier: pid,
                sessionsDirectory: directory,
                expectedWorkingDirectory: "/tmp/another-project"
            )
        )
    }

    func testTitleRefreshUsesLastAITitleAndKeepsFallbackUntilItExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionId = UUID().uuidString.lowercased()
        let transcript = directory.appendingPathComponent("\(sessionId).jsonl")
        let content = """
        {"type":"user","message":{"content":"fallback prompt"}}
        {"type":"ai-title","aiTitle":"First title"}
        {"type":"ai-title","aiTitle":"Latest brief"}

        """
        try Data(content.utf8).write(to: transcript)

        let session = TerminalSession(
            kind: .quick,
            name: "q-1",
            workingDirectory: "/tmp/cld",
            quickLaunch: .resume(sessionId: sessionId)
        )
        session.updateQuickTitle(titlesBySessionId: [:])
        XCTAssertEqual(session.name, "q-1")

        let titles = QuickConversationScanner.scanAITitles(directory: directory)
        session.updateQuickTitle(titlesBySessionId: titles)
        XCTAssertEqual(session.name, "Latest brief")
    }

    func testSelectedSessionTitleChangeInvalidatesWindowState() {
        let state = AppState(windowKind: .quick)
        let session = TerminalSession(
            kind: .quick,
            name: "q-1",
            workingDirectory: "/tmp/cld"
        )
        state.selectedSession = session

        let invalidated = expectation(description: "AppState forwards selected tab title")
        state.objectWillChange
            .sink { invalidated.fulfill() }
            .store(in: &cancellables)

        session.name = "Claude brief"

        wait(for: [invalidated], timeout: 1)
    }
}
