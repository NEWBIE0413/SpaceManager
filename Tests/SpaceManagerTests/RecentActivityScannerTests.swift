import XCTest
@testable import SpaceManager

final class RecentActivityScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTranscript(project: String, session: String, lines: [String], mtime: Date? = nil) throws -> URL {
        let dir = tempDir.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(session).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        return file
    }

    private func scanNow(now: Date = Date()) -> RecentActivityScanner.ScanResult {
        var cache: [String: String] = [:]
        return RecentActivityScanner.scan(projectsDir: tempDir, cwdCache: &cache, now: now)
    }

    func testScanFindsRecentSessionWithCwdAndSnippet() throws {
        _ = try writeTranscript(project: "-tmp-proj", session: "aaaa", lines: [
            #"{"type":"user","cwd":"/tmp/proj","message":{"content":"버그 고쳐줘"}}"#,
            #"{"type":"assistant","cwd":"/tmp/proj","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ])
        let found = scanNow().sessions
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.cwd, "/tmp/proj")
        XCTAssertEqual(found.first?.name, "proj")
        XCTAssertEqual(found.first?.snippet, "버그 고쳐줘")
        XCTAssertEqual(found.first?.id, "aaaa")
    }

    func testScanIgnoresOldSessions() throws {
        _ = try writeTranscript(project: "-tmp-old", session: "bbbb", lines: [
            #"{"type":"user","cwd":"/tmp/old","message":{"content":"오래된 작업"}}"#,
        ], mtime: Date().addingTimeInterval(-7200))
        XCTAssertTrue(scanNow().sessions.isEmpty)
    }

    // 도구 결과·커맨드 메타·caveat은 "무슨 작업이었는지"를 말해주지 않으므로
    // 스니펫 후보에서 제외되고, 그 이전의 진짜 유저 메시지가 뽑혀야 한다
    func testSnippetSkipsMetaMessages() throws {
        _ = try writeTranscript(project: "-tmp-meta", session: "cccc", lines: [
            #"{"type":"user","cwd":"/tmp/meta","message":{"content":"진짜 요청"}}"#,
            #"{"type":"user","cwd":"/tmp/meta","message":{"content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","cwd":"/tmp/meta","message":{"content":"Caveat: the messages below..."}}"#,
        ])
        let found = scanNow().sessions
        XCTAssertEqual(found.first?.snippet, "진짜 요청")
    }

    // 아일랜드 창(1h) 밖이라도 점 창(24h) 안이면 cwd 활동 맵에는 잡혀야 한다
    func testActivityMapCoversDotWindowBeyondIslandWindow() throws {
        let now = Date()
        _ = try writeTranscript(project: "-tmp-w", session: "dddd", lines: [
            #"{"type":"user","cwd":"/tmp/w","message":{"content":"오전 작업"}}"#,
        ], mtime: now.addingTimeInterval(-7200))
        _ = try writeTranscript(project: "-tmp-ancient", session: "eeee", lines: [
            #"{"type":"user","cwd":"/tmp/ancient","message":{"content":"지난주"}}"#,
        ], mtime: now.addingTimeInterval(-90000))
        let result = scanNow(now: now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNotNil(result.activityByCwd["/tmp/w"])
        XCTAssertNil(result.activityByCwd["/tmp/ancient"], "24시간 지난 대화는 점에서 사라져야 한다")
    }

    // 같은 cwd의 세션 여러 개는 가장 최근 시각으로 접힌다
    func testActivityMapKeepsNewestPerCwd() throws {
        let now = Date()
        _ = try writeTranscript(project: "-tmp-m", session: "f111", lines: [
            #"{"type":"user","cwd":"/tmp/m","message":{"content":"a"}}"#,
        ], mtime: now.addingTimeInterval(-600))
        _ = try writeTranscript(project: "-tmp-m", session: "f222", lines: [
            #"{"type":"user","cwd":"/tmp/m","message":{"content":"b"}}"#,
        ], mtime: now.addingTimeInterval(-60))
        let result = scanNow(now: now)
        let recorded = result.activityByCwd["/tmp/m"]
        XCTAssertNotNil(recorded)
        XCTAssertEqual(recorded!.timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 2)
    }

    func testScanSortsByRecencyAndCaps() throws {
        let now = Date()
        for i in 0..<12 {
            _ = try writeTranscript(project: "-tmp-p\(i)", session: "s\(i)", lines: [
                "{\"type\":\"user\",\"cwd\":\"/tmp/p\(i)\",\"message\":{\"content\":\"작업 \(i)\"}}",
            ], mtime: now.addingTimeInterval(TimeInterval(-i * 60)))
        }
        let found = scanNow(now: now).sessions
        XCTAssertEqual(found.count, RecentActivityScanner.maxSessions)
        XCTAssertEqual(found.first?.name, "p0")
        XCTAssertEqual(found.first.map(\.lastActivity), found.map(\.lastActivity).max())
    }
}
