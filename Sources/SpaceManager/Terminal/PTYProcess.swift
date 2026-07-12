import Foundation
import CPty

enum PTYError: Error {
    case forkFailed(Int32)
    case alreadyStarted
}

/// forkpty로 유저 셸을 스폰하고 마스터 fd 입출력을 중계한다.
final class PTYProcess {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var isRunning = false

    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let ioQueue = DispatchQueue(label: "space-manager.pty.io")

    func start(executable: String, execName: String, arguments: [String],
               environment: [String: String], workingDirectory: String,
               cols: UInt16, rows: UInt16) throws {
        guard pid == -1 else { throw PTYError.alreadyStarted }

        // fork 이후 child에서는 async-signal-safe 함수만 안전하므로
        // argv/envp C 배열은 fork 전에 만들어 둔다.
        var argv: [UnsafeMutablePointer<CChar>?] = ([execName] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        let cwd = strdup(workingDirectory)
        let exe = strdup(executable)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(cwd)
            free(exe)
        }

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &ws)
        if child < 0 {
            throw PTYError.forkFailed(errno)
        }
        if child == 0 {
            // 자식: 작업 디렉토리 이동 후 즉시 exec
            _ = chdir(cwd)
            _ = execve(exe, argv, envp)
            _exit(127)
        }

        masterFD = master
        pid = child
        isRunning = true

        // exit 시점에 남은 출력을 논블로킹으로 드레인하기 위해 필요.
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                self.onOutput?(Data(bytes: buffer, count: n))
            } else if n < 0 && errno == EAGAIN {
                // 논블로킹 fd라 지금은 읽을 데이터가 없을 뿐, 소스는 다시 깨어난다.
                return
            } else {
                self.readSource?.cancel()
            }
        }
        // fd는 오직 이 cancel handler에서만, 그리고 정확히 한 번만 닫는다.
        // deinit/terminate는 절대 fd를 직접 close하지 않는다 — cancel()은 비동기라
        // 취소 완료 전에 fd를 닫으면 모니터링 중인 fd를 닫는 UB가 된다.
        // self가 아닌 master 값을 캡처해 self dealloc 이후에도 안전하게 동작한다.
        readSource.setCancelHandler { [master] in
            close(master)
        }
        readSource.resume()
        self.readSource = readSource

        let exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: ioQueue)
        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            let waited = waitpid(self.pid, &status, WNOHANG)
            let code: Int32
            if waited == self.pid {
                code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
            } else {
                code = -1
            }
            // readSource를 취소하기 전에 커널 버퍼에 남은 출력을 모두 비운다 —
            // 그렇지 않으면 child 종료 직전에 쓰인 마지막 출력이 유실될 수 있다.
            self.drainRemainingOutput()
            self.readSource?.cancel()
            self.exitSource?.cancel()
            self.isRunning = false
            self.onExit?(code)
        }
        exitSource.resume()
        self.exitSource = exitSource
    }

    /// 논블로킹 마스터 fd에서 더 읽을 데이터가 없을 때까지(<= 0) 반복해서 읽어
    /// onOutput으로 전달한다. exit 처리 중 readSource를 취소하기 직전에만 호출한다.
    private func drainRemainingOutput() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(masterFD, &buffer, buffer.count)
            guard n > 0 else { break }
            onOutput?(Data(bytes: buffer, count: n))
        }
    }

    func write(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(self.masterFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        _ = cpty_set_winsize(masterFD, rows, cols)
    }

    func terminate() {
        guard pid > 0, isRunning else { return }
        kill(pid, SIGHUP)
    }

    deinit {
        // fd는 readSource의 cancel handler가 닫는다 — 여기서 직접 close하지 않는다.
        if pid > 0, isRunning { kill(pid, SIGHUP) }
        readSource?.cancel()
        exitSource?.cancel()
    }
}
