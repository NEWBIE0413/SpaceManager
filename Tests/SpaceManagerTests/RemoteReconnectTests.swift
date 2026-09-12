import XCTest
@testable import SpaceManager

final class RemoteReconnectTests: XCTestCase {
    func testConnectionLossBacksOffAndRecoversAfterStableConnection() {
        let delays = (0...6).map {
            RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: "arch", exitCode: 255,
                                        attempt: $0, connectedFor: 1)
        }
        XCTAssertEqual(delays, [3, 6, 12, 24, 30, 30, 30])
        XCTAssertEqual(RemoteReconnectPolicy.delay(kind: .tmuxExtra, remoteHost: "arch", exitCode: -1,
                                                   attempt: 6, connectedFor: 40), 3)
    }

    func testExplicitDetachAndEphemeralShellsDoNotRestart() {
        XCTAssertNil(RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: "arch", exitCode: 0, attempt: 0, connectedFor: 1))
        for kind: TabKind in [.shell, .quick] {
            XCTAssertNil(RemoteReconnectPolicy.delay(kind: kind, remoteHost: "arch", exitCode: 255, attempt: 0, connectedFor: 1))
        }
        XCTAssertNil(RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: nil, exitCode: 1, attempt: 0, connectedFor: 1))
    }

    func testFailedManagedRestoreDoesNotCreateAnEmptyReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".config/systemd/user/tmux-server.service.d/persistence.conf")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("systemctl", "exit 1"), ("tmux", "touch \"$HOME/tmux-was-called\"; exit 0")] {
            let file = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", TmuxBootstrap.remoteStartupScript(sessionName: "project", remoteDirectory: .relativeToHome("project"))]
        process.environment = ["HOME": root.path, "PATH": bin.path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tmux-was-called").path))
    }

    func testHostChangePreservesExtraTabIdentityAndSession() {
        let original = TerminalSession(kind: .tmuxExtra, name: "review", workingDirectory: "/Users/me/project", tmuxSessionName: "project-3")
        let remote = original.retargeted(to: "arch")
        XCTAssertEqual(remote.id, original.id)
        XCTAssertEqual(remote.name, "review")
        XCTAssertEqual(remote.kind, .tmuxExtra)
        XCTAssertEqual(remote.tmuxSessionName, "project-3")
        XCTAssertEqual(remote.workingDirectory, original.workingDirectory)
        XCTAssertEqual(remote.remoteHost, "arch")
        XCTAssertNil(remote.retargeted(to: nil).remoteHost)
    }
}
