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
    func testCodexMetadataIsCachedUntilFileChangesAndExpiresByEventTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = tempDir.appendingPathComponent("codex.jsonl")
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let content = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id\",\"cwd\":\"/tmp/project\"}}\n"
            + "{\"timestamp\":\"\(stamp)\",\"payload\":{\"type\":\"user_message\",\"message\":\"initial\"}}\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        var cache = AgentActivitySources.Cache()
        let first = AgentActivitySources.scanCodex(sessionsDir: tempDir, cache: &cache, now: now)
        XCTAssertEqual(first.first?.snippet, "initial")
        XCTAssertEqual(AgentActivitySources.scanCodex(sessionsDir: tempDir, cache: &cache, now: now), first)
        XCTAssertEqual(cache.loadCount, 1)
        let changed = content.replacingOccurrences(of: "initial", with: "changed")
        try changed.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        XCTAssertEqual(AgentActivitySources.scanCodex(sessionsDir: tempDir, cache: &cache, now: now).first?.snippet, "changed")
        XCTAssertEqual(cache.loadCount, 2)
        XCTAssertTrue(AgentActivitySources.scanCodex(sessionsDir: tempDir, cache: &cache,
            now: now.addingTimeInterval(90_000)).isEmpty)
        XCTAssertEqual(cache.codex.count, 0)
    }

    func testClassicGeminiReusesProjectAndSessionMetadataAndReflectsReplacement() throws {
        let chats = tempDir.appendingPathComponent("tmp/project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try #"{"projects":{"/tmp/gemini":"project"}}"#.write(
            to: tempDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
        let file = chats.appendingPathComponent("session-1.json")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let content = "{\"sessionId\":\"one\",\"lastUpdated\":\"\(stamp)\",\"messages\":[{\"type\":\"user\",\"content\":\"first\"}]}"
        try content.write(to: file, atomically: true, encoding: .utf8)
        var cache = AgentActivitySources.Cache()
        XCTAssertEqual(AgentActivitySources.scanGemini(geminiDir: tempDir, cache: &cache).first?.snippet, "first")
        _ = AgentActivitySources.scanGemini(geminiDir: tempDir, cache: &cache)
        XCTAssertEqual(cache.loadCount, 2)
        try content.replacingOccurrences(of: "first", with: "next").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentActivitySources.scanGemini(geminiDir: tempDir, cache: &cache).first?.snippet, "next")
        XCTAssertEqual(cache.loadCount, 3)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(AgentActivitySources.scanGemini(geminiDir: tempDir, cache: &cache).isEmpty)
        XCTAssertEqual(cache.classic.count, 0)
    }

}
