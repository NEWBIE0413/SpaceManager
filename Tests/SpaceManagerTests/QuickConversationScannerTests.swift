import XCTest
@testable import SpaceManager

final class QuickConversationScannerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-conversations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLastAITitleWinsAndResultsSortByMtime() throws {
        let older = try writeTranscript([
            #"{"type":"user","message":{"content":"첫 질문"}}"#,
            #"{"type":"ai-title","aiTitle":"이전 제목"}"#,
            #"{"type":"ai-title","aiTitle":"최종 제목"}"#,
        ], modifiedAt: Date(timeIntervalSince1970: 100))
        let newer = try writeTranscript([
            #"{"type":"user","message":{"content":"새 대화"}}"#,
        ], modifiedAt: Date(timeIntervalSince1970: 200))

        let result = QuickConversationScanner.scan(directory: directory)
        XCTAssertEqual(result.map(\.id), [
            newer.deletingPathExtension().lastPathComponent,
            older.deletingPathExtension().lastPathComponent,
        ])
        XCTAssertEqual(result.map(\.title), ["새 대화", "최종 제목"])
    }

    func testFirstNonMetaUserMessageIsFallbackTitle() throws {
        _ = try writeTranscript([
            #"{"type":"user","message":{"content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","message":{"content":"실제 첫 질문"}}"#,
            #"{"type":"user","message":{"content":"두 번째 질문"}}"#,
        ], modifiedAt: Date())

        XCTAssertEqual(
            QuickConversationScanner.scan(directory: directory).first?.title,
            "실제 첫 질문"
        )
    }

    func testSameNormalizedTitleKeepsNewestResumeFile() throws {
        _ = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"같은   대화"}"#,
        ], modifiedAt: Date(timeIntervalSince1970: 100))
        let resumed = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"같은 대화"}"#,
        ], modifiedAt: Date(timeIntervalSince1970: 300))

        let result = QuickConversationScanner.scan(directory: directory)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, resumed.deletingPathExtension().lastPathComponent)
    }

    func testPagingReadsOnlyRequestedRowsAndKeepsTrackedTitleOutsidePage() throws {
        let now = Date()
        var files: [URL] = []
        for i in 0..<75 {
            files.append(try writeTranscript([
                "{\"type\":\"ai-title\",\"aiTitle\":\"conversation \(i)\"}",
            ], modifiedAt: now.addingTimeInterval(Double(-i))))
        }
        let trackedID = files[74].deletingPathExtension().lastPathComponent
        var index = TranscriptTitleIndex()
        let first = QuickConversationScanner.scanClaude(directory: directory, limit: 31,
            tracked: [trackedID], index: &index)
        XCTAssertEqual(first.rows.count, 31)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.titles[trackedID], "conversation 74")
        XCTAssertEqual(index.cachedFileCount, 32)
        let bytes = index.bytesRead
        _ = QuickConversationScanner.scanClaude(directory: directory, limit: 31,
            tracked: [trackedID], index: &index)
        XCTAssertEqual(index.bytesRead, bytes)
        let next = QuickConversationScanner.scanClaude(directory: directory, limit: 61,
            tracked: [trackedID], index: &index)
        XCTAssertEqual(next.rows.count, 61)
        XCTAssertEqual(Array(next.rows.prefix(31)), first.rows)
        let all = QuickConversationScanner.scanClaude(directory: directory, limit: 100,
            tracked: [], index: &index)
        XCTAssertEqual(all.rows.count, 75)
        XCTAssertFalse(all.hasMore)
        try FileManager.default.removeItem(at: files[0])
        let deleted = QuickConversationScanner.scanClaude(directory: directory, limit: 100,
            tracked: [], index: &index)
        XCTAssertEqual(deleted.rows.count, 74)
        XCTAssertEqual(index.cachedFileCount, 74)
    }

    private func writeTranscript(_ lines: [String], modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}
