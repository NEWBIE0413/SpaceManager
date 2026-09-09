import XCTest
@testable import SpaceManager

final class DirectoryWatcherTests: XCTestCase {
    func testWritesAreDeliveredWithoutPollingAndStopCancelsDelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.jsonl")
        let received = expectation(description: "FSEvents delivers changed file")
        let watcher = DirectoryWatcher()
        var delivered = false
        watcher.onPathsChange = { paths, _ in
            XCTAssertTrue(Thread.isMainThread)
            let normalized = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            if normalized.contains(file.resolvingSymlinksInPath().path), !delivered {
                delivered = true
                received.fulfill()
            }
        }
        watcher.start(path: directory.path)
        XCTAssertTrue(watcher.isWatching)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do { try Data("{}\n".utf8).write(to: file) }
            catch { XCTFail("\(error)") }
        }
        wait(for: [received], timeout: 5)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        let stopped = expectation(description: "No callbacks after stop")
        stopped.isInverted = true
        watcher.onPathsChange = { _, _ in stopped.fulfill() }
        try Data("second\n".utf8).write(to: file)
        wait(for: [stopped], timeout: 0.5)
    }

    func testMissingRootCanBeStartedAfterItIsCreated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = DirectoryWatcher()
        watcher.start(path: directory.path)
        XCTAssertFalse(watcher.isWatching)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher.start(path: directory.path)
        XCTAssertTrue(watcher.isWatching)
        watcher.stop()
    }
}
