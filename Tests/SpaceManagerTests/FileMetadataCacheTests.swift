import XCTest
@testable import SpaceManager

final class FileMetadataCacheTests: XCTestCase {
    func testUnchangedAppendReplacementAndDeletion() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var cache = FileMetadataCache<String>()
        func read() -> String? { try? String(contentsOf: file) }
        try "first".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.value(for: file, load: read), "first")
        for _ in 0..<20 { XCTAssertEqual(cache.value(for: file, load: read), "first") }
        XCTAssertEqual(cache.loadCount, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" appended".utf8))
        try handle.close()
        XCTAssertEqual(cache.value(for: file, load: read), "first appended")
        let signature = try XCTUnwrap(FileSignature.read(file))
        try "other replaced".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: signature.modified], ofItemAtPath: file.path)
        XCTAssertEqual(cache.value(for: file, load: read), "other replaced")
        XCTAssertEqual(cache.loadCount, 3, "Atomic same-size replacement must invalidate even with the old mtime")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(cache.value(for: file, load: read))
        XCTAssertEqual(cache.count, 0)
    }

    func testNegativeEntriesAreCachedAndUnvisitedEntriesAreEvicted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        var cache = FileMetadataCache<String>()
        cache.beginPass()
        XCTAssertNil(cache.value(for: file) { nil })
        cache.endPass()
        cache.beginPass()
        XCTAssertNil(cache.value(for: file) { XCTFail("An unchanged empty record must not be parsed again"); return nil })
        cache.endPass()
        XCTAssertEqual(cache.loadCount, 1)
        cache.beginPass()
        cache.endPass()
        XCTAssertEqual(cache.count, 0)
    }
}
