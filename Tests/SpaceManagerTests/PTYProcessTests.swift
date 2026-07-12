import XCTest
@testable import SpaceManager

final class PTYProcessTests: XCTestCase {
    func testEchoProducesOutputAndExits() throws {
        let pty = PTYProcess()
        let gotOutput = expectation(description: "output")
        gotOutput.assertForOverFulfill = false
        let exited = expectation(description: "exit")
        var collected = Data()
        var exitCode: Int32 = -999
        let lock = NSLock()

        pty.onOutput = { data in
            lock.lock(); collected.append(data); lock.unlock()
            gotOutput.fulfill()
        }
        pty.onExit = { code in
            exitCode = code
            exited.fulfill()
        }

        try pty.start(
            executable: "/bin/echo", execName: "echo", arguments: ["hello-pty"],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )
        wait(for: [gotOutput, exited], timeout: 10)
        lock.lock()
        let text = String(data: collected, encoding: .utf8) ?? ""
        lock.unlock()
        XCTAssertTrue(text.contains("hello-pty"))
        XCTAssertEqual(exitCode, 0)
    }

    func testWriteReachesChildProcess() throws {
        let pty = PTYProcess()
        let sawEcho = expectation(description: "cat echoes input")
        pty.onOutput = { data in
            if let s = String(data: data, encoding: .utf8), s.contains("ping-42") {
                sawEcho.fulfill()
            }
        }
        try pty.start(
            executable: "/bin/cat", execName: "cat", arguments: [],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )
        pty.write(Data("ping-42\n".utf8))
        wait(for: [sawEcho], timeout: 10)
        pty.terminate()
    }
}
