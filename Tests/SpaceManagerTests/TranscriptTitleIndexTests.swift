import XCTest
@testable import SpaceManager

final class TranscriptTitleIndexTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("session.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testUnchangedFileReadsNoBytesAndAppendReadsOnlyNewBytes() throws {
        let initial = Data((#"{"type":"ai-title","aiTitle":"old"}"# + "\n" + String(repeating: "{}\n", count: 100_000)).utf8)
        try initial.write(to: file)
        var index = TranscriptTitleIndex()
        XCTAssertEqual(index.metadata(for: file)?.title, "old")
        XCTAssertEqual(index.bytesRead, initial.count)
        for _ in 0..<20 { XCTAssertEqual(index.metadata(for: file)?.title, "old") }
        XCTAssertEqual(index.bytesRead, initial.count)
        let extra = Data((#"{"type":"ai-title","aiTitle":"new"}"# + "\n").utf8)
        try append(extra)
        XCTAssertEqual(index.metadata(for: file)?.title, "new")
        XCTAssertEqual(index.bytesRead, initial.count + extra.count)
    }

    func testPartialUnicodeAndFinalRecordWithoutNewline() throws {
        let line = Data(#"{"type":"ai-title","aiTitle":"한글 제목"}"#.utf8)
        let firstUnicodeByte = try XCTUnwrap(line.firstIndex(of: 0xed))
        try line.prefix(firstUnicodeByte + 1).write(to: file)
        var index = TranscriptTitleIndex()
        XCTAssertNil(index.metadata(for: file)?.title)
        try append(line.dropFirst(firstUnicodeByte + 1))
        XCTAssertEqual(index.metadata(for: file)?.title, "한글 제목")
        try append(Data(("\n" + #"{"type":"ai-title","aiTitle":"다음 제목"}"# + "\n").utf8))
        XCTAssertEqual(index.metadata(for: file)?.title, "다음 제목")
    }

    func testOversizedToolRecordDoesNotHideFollowingTitle() throws {
        let content = #"{"type":"tool-result","data":""#
            + String(repeating: "a", count: TranscriptTitleIndex.maximumLineBytes * 4)
            + "\"}\n" + #"{"type":"ai-title","aiTitle":"after tool"}"# + "\n"
        try Data(content.utf8).write(to: file)
        var index = TranscriptTitleIndex()
        XCTAssertEqual(index.metadata(for: file)?.title, "after tool")
    }

    func testReplacementTruncationAndSameSizeRewriteResetMetadata() throws {
        let old = Data((#"{"type":"ai-title","aiTitle":"old"}"# + "\n").utf8)
        let new = Data((#"{"type":"ai-title","aiTitle":"new"}"# + "\n").utf8)
        try old.write(to: file)
        var index = TranscriptTitleIndex()
        XCTAssertEqual(index.metadata(for: file)?.title, "old")
        let before = try XCTUnwrap(FileSignature.read(file))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: new)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: before.modified.addingTimeInterval(1)], ofItemAtPath: file.path)
        XCTAssertEqual(index.metadata(for: file)?.title, "new")
        try old.write(to: file, options: .atomic)
        XCTAssertEqual(index.metadata(for: file)?.title, "old")
        let truncate = try FileHandle(forWritingTo: file)
        try truncate.truncate(atOffset: 0)
        try truncate.close()
        XCTAssertNil(index.metadata(for: file)?.title)
        index.retain(paths: [])
        XCTAssertEqual(index.cachedFileCount, 0)
    }
}
