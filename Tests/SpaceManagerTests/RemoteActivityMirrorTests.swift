import XCTest
@testable import SpaceManager

final class RemoteActivityMirrorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func snapshot(generatedAt: Double, records: [[String: Any]], home: String = "/home/me") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": 1, "host": "myworld", "home": home, "generatedAt": generatedAt, "records": records,
        ])
    }

    func testLocalPathMapsRemoteHomeAndLeavesOtherPathsAlone() {
        XCTAssertEqual(RemoteActivityMirror.localPath(forRemoteCwd: "/home/me/myworld/flat", remoteHome: "/home/me", localHome: "/Users/me"),
                       "/Users/me/myworld/flat")
        XCTAssertEqual(RemoteActivityMirror.localPath(forRemoteCwd: "/home/me", remoteHome: "/home/me/", localHome: "/Users/me"), "/Users/me")
        XCTAssertEqual(RemoteActivityMirror.localPath(forRemoteCwd: "/srv/app", remoteHome: "/home/me", localHome: "/Users/me"), "/srv/app")
        XCTAssertEqual(RemoteActivityMirror.localPath(forRemoteCwd: "/home/meow/x", remoteHome: "/home/me", localHome: "/Users/me"), "/home/meow/x",
                       "홈 접두사는 경로 요소 단위로만 일치해야 한다")
    }

    func testParseAndConvertProduceHostTaggedRecordsWithSkewCorrectedGenerating() throws {
        let remoteNow = 1_000_000.0
        let data = snapshot(generatedAt: remoteNow, records: [
            ["provider": "claude", "id": "aaaa", "cwd": "/home/me/myworld/flat", "mtime": remoteNow - 1,
             "lastActivity": remoteNow - 1, "snippet": "원격 작업"],
            ["provider": "codex", "id": "cccc", "cwd": "/home/me/proj", "mtime": remoteNow - 600,
             "lastActivity": remoteNow - 600],
            ["provider": "claude", "id": "copied", "cwd": "/Users/me/cld", "mtime": remoteNow, "lastActivity": remoteNow],
            ["provider": "gemini", "id": "bad"],   // 필수 필드 없음 → 무시
        ])
        let parsed = try XCTUnwrap(RemoteActivityMirror.parse(data))
        XCTAssertEqual(parsed.records.count, 3)

        // 로컬 시계가 원격보다 100초 앞서 있고, 요약은 방금(2초 전) 도착했다
        let localNow = Date(timeIntervalSince1970: remoteNow + 100 + 2)
        let fileModified = Date(timeIntervalSince1970: remoteNow + 100)
        let result = RemoteActivityMirror.convert(parsed, host: "arch", localHome: "/Users/me",
                                                  fileModified: fileModified, now: localNow)
        XCTAssertEqual(result.records.map(\.id), ["arch:claude:aaaa", "arch:codex:cccc"],
                       "맥에서 복사해 간 transcript(로컬 홈 경로)는 원격 활동이 아니다")
        XCTAssertEqual(result.records[0].cwd, "/Users/me/myworld/flat")
        XCTAssertEqual(result.records[0].host, "arch")
        XCTAssertEqual(result.records[0].snippet, "원격 작업")
        XCTAssertNil(result.records[0].growingFile)
        XCTAssertEqual(result.records[1].lastActivity.timeIntervalSince1970, remoteNow - 600, accuracy: 0.001)

        // 생성 중: 원격 mtime(1초 전)에 스큐(+100초)를 더하면 로컬 기준으로도 3초 전이다
        let index = GeneratingActivityIndex(entries: result.generating)
        XCTAssertEqual(index.directories(now: localNow), ["/Users/me/myworld/flat"])
        XCTAssertEqual(result.generating.keys.sorted(), ["remote/arch:claude:aaaa", "remote/arch:codex:cccc"])
    }

    func testStaleSnapshotKeepsActivityButNotGenerating() throws {
        let remoteNow = 1_000_000.0
        let parsed = try XCTUnwrap(RemoteActivityMirror.parse(snapshot(generatedAt: remoteNow, records: [
            ["provider": "claude", "id": "aaaa", "cwd": "/home/me/p", "mtime": remoteNow, "lastActivity": remoteNow],
        ])))
        let fileModified = Date(timeIntervalSince1970: remoteNow)
        let result = RemoteActivityMirror.convert(parsed, host: "arch", localHome: "/Users/me", fileModified: fileModified,
                                                  now: fileModified.addingTimeInterval(RemoteActivityMirror.staleWindow + 1))
        XCTAssertEqual(result.records.count, 1, "미러가 멈춰도 마지막으로 안 활동은 점으로 남는다")
        XCTAssertTrue(result.generating.isEmpty, "미러가 멈추면 생성 중 표시는 만들지 않는다")
    }

    func testScanReadsEveryHostDirectoryAndSkipsBrokenFiles() throws {
        let arch = tempDir.appendingPathComponent("arch")
        let nuc = tempDir.appendingPathComponent("nuc")
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nuc, withIntermediateDirectories: true)
        let now = Date()
        try snapshot(generatedAt: now.timeIntervalSince1970, records: [
            ["provider": "claude", "id": "a", "cwd": "/home/me/x", "mtime": now.timeIntervalSince1970,
             "lastActivity": now.timeIntervalSince1970],
        ]).write(to: arch.appendingPathComponent("activity.json"))
        try Data("not json".utf8).write(to: nuc.appendingPathComponent("activity.json"))
        let result = RemoteActivityMirror.scan(mirrorsDir: tempDir, localHome: "/Users/me", now: now)
        XCTAssertEqual(result.records.map(\.id), ["arch:claude:a"])
        XCTAssertEqual(result.records.first?.cwd, "/Users/me/x")
        XCTAssertEqual(RemoteActivityMirror.scan(mirrorsDir: tempDir.appendingPathComponent("missing")).records, [])
    }

    // 스캐너 통합: 로컬 결과와 원격 요약이 합쳐져 점·아일랜드·생성 중에 모두 반영된다
    @MainActor
    func testScannerMergesRemoteSnapshotIntoPublishedState() throws {
        let projects = tempDir.appendingPathComponent("projects")
        let mirrors = tempDir.appendingPathComponent("remote")
        let arch = mirrors.appendingPathComponent("arch")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-tmp-local"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"/tmp/local","message":{"content":"로컬"}}"#
            .write(to: projects.appendingPathComponent("-tmp-local/1111.jsonl"), atomically: true, encoding: .utf8)
        let now = Date().timeIntervalSince1970
        let home = NSHomeDirectory()
        try snapshot(generatedAt: now, records: [
            ["provider": "codex", "id": "rrrr", "cwd": "/home/me/myworld/flat", "mtime": now, "lastActivity": now, "snippet": "원격"],
        ]).write(to: arch.appendingPathComponent("activity.json"))

        let scanner = RecentActivityScanner(
            projectsDir: projects, codexSessionsDir: tempDir.appendingPathComponent("codex"),
            geminiDir: tempDir.appendingPathComponent("gemini"), remoteMirrorsDir: mirrors
        )
        scanner.setVisible(true)
        defer { scanner.setVisible(false) }
        let published = expectation(description: "scan")
        var attempts = 0
        func poll() {
            if scanner.sessions.contains(where: { $0.host == "arch" }) || attempts > 50 { published.fulfill(); return }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
        wait(for: [published], timeout: 8)

        let remote = try XCTUnwrap(scanner.sessions.first { $0.host == "arch" })
        XCTAssertEqual(remote.cwd, home + "/myworld/flat")
        XCTAssertEqual(remote.name, "flat")
        XCTAssertEqual(remote.snippet, "원격")
        XCTAssertTrue(scanner.sessions.contains { $0.cwd == "/tmp/local" && $0.host == nil })
        XCTAssertNotNil(scanner.workspaceActivity[home + "/myworld/flat"])
        XCTAssertTrue(scanner.generatingDirectories.contains(home + "/myworld/flat"))
    }
}
