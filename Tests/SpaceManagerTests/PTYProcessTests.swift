import XCTest
@testable import SpaceManager

final class PTYProcessTests: XCTestCase {
    func testReleasedPTYReapsStoppedChild() throws {
        var pty: PTYProcess? = PTYProcess()
        try pty?.start(
            executable: "/bin/cat", execName: "cat", arguments: [],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )
        let child = try XCTUnwrap(pty?.processIdentifier)
        var cleanupStatus: Int32 = 0
        defer {
            if kill(child, 0) == 0 {
                _ = kill(child, SIGCONT)
                _ = kill(child, SIGKILL)
                _ = waitpid(child, &cleanupStatus, 0)
            }
        }

        // 종료보다 객체 해제가 반드시 앞서도록 자식을 멈춘다. 이 순서를 고정하지
        // 않으면 기존 exitSource가 먼저 회수해 회귀가 확률적으로만 드러난다.
        XCTAssertEqual(kill(child, SIGSTOP), 0)
        var stoppedStatus: Int32 = 0
        let stopDeadline = Date().addingTimeInterval(1)
        var stopResult: pid_t = 0
        while Date() < stopDeadline, stopResult == 0 {
            stopResult = waitpid(child, &stoppedStatus, WUNTRACED | WNOHANG)
            if stopResult == 0 { usleep(5_000) }
        }
        XCTAssertEqual(stopResult, child)

        weak var releasedPTY: PTYProcess?
        releasedPTY = pty
        pty?.terminate(force: true)
        pty = nil
        XCTAssertNil(releasedPTY)
        XCTAssertEqual(kill(child, SIGCONT), 0)

        let reapDeadline = Date().addingTimeInterval(2)
        while Date() < reapDeadline {
            errno = 0
            if kill(child, 0) == -1, errno == ESRCH { break }
            usleep(10_000)
        }

        var status: Int32 = 0
        errno = 0
        let waited = waitpid(child, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(waited, -1, "child was left waitable (usually a zombie)")
        XCTAssertEqual(waitError, ECHILD)
    }

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
        // PTY line discipline echo와 cat 출력이 별도 read로 오면 같은 문자열을
        // 두 번 관찰할 수 있다. 한 번 이상 도달했는지만 이 테스트의 계약이다.
        sawEcho.assertForOverFulfill = false
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

    func testForceTerminateEndsDirectChild() throws {
        let pty = PTYProcess()
        let exited = expectation(description: "direct child exits on SIGTERM")
        pty.onExit = { _ in exited.fulfill() }
        try pty.start(
            executable: "/bin/cat", execName: "cat", arguments: [],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )

        pty.terminate(force: true)
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(pty.isRunning)
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
