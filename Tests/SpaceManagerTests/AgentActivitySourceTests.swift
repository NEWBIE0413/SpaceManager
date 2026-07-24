import XCTest
@testable import SpaceManager

final class AgentActivitySourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCodexSessionUsesMetaCwdAndLastEventTimestamp() throws {
        let sessions = tempDir.appendingPathComponent("codex/2026/07/22")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-22T01:00:00.000Z","type":"session_meta","payload":{"id":"codex-id","cwd":"/tmp/codex-project"}}"#,
            #"{"timestamp":"2026-07-22T01:04:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Codex request"}}"#,
            #"{"timestamp":"2026-07-22T01:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-22T01:06:00Z"))

        let record = try XCTUnwrap(AgentActivitySources.scanCodex(
            sessionsDir: tempDir.appendingPathComponent("codex"), now: now
        ).first)
        XCTAssertEqual(record.provider, .codex)
        XCTAssertEqual(record.cwd, "/tmp/codex-project")
        XCTAssertEqual(record.snippet, "Codex request")
        XCTAssertEqual(record.lastActivity.timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            record.growingFile?.resolvingSymlinksInPath(),
            file.resolvingSymlinksInPath()
        )
    }

    func testAntigravityHistoryMapsConversationToWorkspaceAndGrowingTranscript() throws {
        let root = tempDir.appendingPathComponent("antigravity-cli")
        let conversationID = "gemini-id"
        let transcript = root.appendingPathComponent("brain/\(conversationID)/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"created_at":"2026-07-22T01:05:30Z","source":"MODEL","type":"PLANNER_RESPONSE"}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = #"{"conversationId":"gemini-id","timestamp":1784682300000,"workspace":"/tmp/gemini-project","display":"Gemini request"}"#
        try history.write(to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-22T01:06:00Z"))

        let record = try XCTUnwrap(AgentActivitySources.scanGemini(geminiDir: tempDir, now: now).first)
        XCTAssertEqual(record.provider, .gemini)
        XCTAssertEqual(record.cwd, "/tmp/gemini-project")
        XCTAssertEqual(record.snippet, "Gemini request")
        XCTAssertEqual(record.growingFile, transcript)
        XCTAssertEqual(record.lastActivity.timeIntervalSince1970, now.addingTimeInterval(-30).timeIntervalSince1970, accuracy: 1)
    }
}
