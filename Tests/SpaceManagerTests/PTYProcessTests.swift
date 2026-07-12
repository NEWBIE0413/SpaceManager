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

    /// 큰 페이로드를 단일 write() 호출로 보내 pending-write/EAGAIN 경로에서
    /// tail이 잘리지 않는지 검증한다. EAGAIN이 실제로 발생하는지는 tty 입력 버퍼
    /// 크기에 달려 있어 보장할 수 없지만, 만약 구현이 다시 "n <= 0이면 그냥 중단"
    /// 방식으로 퇴행하면 이 테스트는 결정적으로 실패한다(마지막 줄이 누락됨).
    func testLargeSingleWriteIsNotTruncated() throws {
        let pty = PTYProcess()
        let sawFirst = expectation(description: "saw first marker")
        let sawLast = expectation(description: "saw last marker")
        sawFirst.assertForOverFulfill = false
        sawLast.assertForOverFulfill = false
        var collected = Data()
        let lock = NSLock()

        pty.onOutput = { data in
            lock.lock()
            collected.append(data)
            let text = String(data: collected, encoding: .utf8) ?? ""
            lock.unlock()
            if text.contains("line-0-") { sawFirst.fulfill() }
            if text.contains("line-199-") { sawLast.fulfill() }
        }

        try pty.start(
            executable: "/bin/cat", execName: "cat", arguments: [],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )

        let filler = String(repeating: "x", count: 60)
        var payload = ""
        for i in 0..<200 {
            payload += "line-\(i)-\(filler)\n"
        }
        pty.write(Data(payload.utf8))

        wait(for: [sawFirst, sawLast], timeout: 10)

        lock.lock()
        let text = String(data: collected, encoding: .utf8) ?? ""
        lock.unlock()
        XCTAssertTrue(text.contains("line-0-"))
        XCTAssertTrue(text.contains("line-199-"))

        pty.terminate()
    }
}
