import XCTest
@testable import SpaceManager

/// scripts/remote-activity-summary.py는 원격에서 돌지만 형식은 여기서 검증한다 —
/// 같은 python3로 합성 transcript를 읽혀 Swift 파서가 그대로 받아들이는지 본다.
final class RemoteActivitySummaryScriptTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("remote-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-home-me-proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions/2026/09/12"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/remote-activity-summary.py")
    }

    private func runSummarizer() throws -> RemoteActivityMirror.Snapshot {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        process.environment = env
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(RemoteActivityMirror.parse(data), String(decoding: data, as: UTF8.self))
    }

    func testSummarizesRecentClaudeAndCodexTranscriptsOnly() throws {
        let claude = home.appendingPathComponent(".claude/projects/-home-me-proj/1111.jsonl")
        try [
            #"{"type":"user","cwd":"/home/me/proj","timestamp":"2026-09-12T10:00:00.000Z","message":{"content":"진짜 요청"}}"#,
            #"{"type":"user","cwd":"/home/me/proj","timestamp":"2026-09-12T10:00:05.000Z","message":{"content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"assistant","cwd":"/home/me/proj","timestamp":"2026-09-12T10:00:09.000Z","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ].joined(separator: "\n").write(to: claude, atomically: true, encoding: .utf8)
        // 맥에서 tar로 딸려온 AppleDouble 파일은 무시
        try "junk".write(to: home.appendingPathComponent(".claude/projects/-home-me-proj/._1111.jsonl"), atomically: true, encoding: .utf8)
        let old = home.appendingPathComponent(".claude/projects/-home-me-proj/2222.jsonl")
        try #"{"type":"user","cwd":"/home/me/old","message":{"content":"옛날"}}"#.write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old.path)
        let codex = home.appendingPathComponent(".codex/sessions/2026/09/12/rollout-x.jsonl")
        try [
            #"{"timestamp":"2026-09-12T11:00:00.000Z","type":"session_meta","payload":{"id":"codex-id","cwd":"/home/me/codex"}}"#,
            #"{"timestamp":"2026-09-12T11:04:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Codex request"}}"#,
            #"{"timestamp":"2026-09-12T11:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)

        let snapshot = try runSummarizer()
        XCTAssertEqual(snapshot.home, home.path)
        XCTAssertEqual(Date().timeIntervalSince(snapshot.generatedAt), 0, accuracy: 30)
        XCTAssertEqual(snapshot.records.count, 2)
        let claudeRecord = try XCTUnwrap(snapshot.records.first { $0.provider == .claude })
        XCTAssertEqual(claudeRecord.id, "1111")
        XCTAssertEqual(claudeRecord.cwd, "/home/me/proj")
        XCTAssertEqual(claudeRecord.snippet, "진짜 요청")
        XCTAssertEqual(claudeRecord.lastActivity, ISO8601DateFormatter().date(from: "2026-09-12T10:00:09Z"))
        let codexRecord = try XCTUnwrap(snapshot.records.first { $0.provider == .codex })
        XCTAssertEqual(codexRecord.id, "codex-id")
        XCTAssertEqual(codexRecord.cwd, "/home/me/codex")
        XCTAssertEqual(codexRecord.snippet, "Codex request")
        XCTAssertEqual(codexRecord.lastActivity, ISO8601DateFormatter().date(from: "2026-09-12T11:05:00Z"))
    }
}
