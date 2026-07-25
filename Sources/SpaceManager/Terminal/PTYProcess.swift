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
    private var writeSource: DispatchSourceWrite?
    private var pendingWrite = Data()
    private var isNonBlocking = false
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
        // 기존 플래그를 보존한 채 O_NONBLOCK만 더한다 — F_SETFL을 통째로 덮어쓰면
        // forkpty가 이미 설정해 둔 다른 플래그를 잃을 수 있다. fcntl이 실패하면
        // fd는 블로킹 상태로 남고, isNonBlocking이 false가 되어 드레인 루프를 건너뛴다.
        let flags = fcntl(master, F_GETFL)
        if flags != -1 {
            isNonBlocking = fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1
        } else {
            isNonBlocking = false
        }

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
        // master 값을 별도로 캡처해 self dealloc 이후에도 close는 안전하게 동작한다.
        // close 뒤에는 masterFD를 -1로 되돌려, 재활용된 fd 번호로 이후의 write/resize가
        // 실수로 흘러들어가지 않게 막는다. 이 핸들러는 ioQueue에서 실행되므로 masterFD를
        // 읽고 쓰는 다른 모든 코드(write/resize/flushPendingWrite)와 자연히 직렬화된다.
        // writeSource도 여기서 함께 취소한다 — 닫힌 fd에 대해 다시는 발화하지 않도록.
        readSource.setCancelHandler { [weak self, master] in
            close(master)
            guard let self else { return }
            self.masterFD = -1
            if let writeSource = self.writeSource {
                self.writeSource = nil
                writeSource.cancel()
            }
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
            // fcntl이 실패해 fd가 여전히 블로킹 상태라면, 더 읽을 데이터가 없을 때
            // read가 영원히 블록될 위험이 있으므로 논블로킹 설정에 성공했을 때만 드레인한다.
            if self.isNonBlocking {
                self.drainRemainingOutput()
            }
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
            self.pendingWrite.append(data)
            self.flushPendingWrite()
        }
    }

    /// ioQueue에서만 호출된다. pendingWrite를 가능한 만큼 flush한다. fd가 논블로킹이라
    /// tty 입력 버퍼가 가득 차면 Darwin.write가 EAGAIN을 반환할 수 있는데, 예전처럼
    /// 그 자리에서 루프를 끝내버리면 남은 바이트를 조용히 유실한다(예: 느린 자식 프로세스로의
    /// 큰 paste가 잘림). 대신 writeSource로 "다시 쓸 수 있는 시점"을 기다렸다가 이어서
    /// flush한다 — ioQueue는 readSource와 공유하는 큐이므로 절대 poll/sleep로 막지 않는다.
    private func flushPendingWrite() {
        guard masterFD >= 0 else {
            pendingWrite.removeAll()
            return
        }
        while !pendingWrite.isEmpty {
            let n = pendingWrite.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(masterFD, base, raw.count)
            }
            if n > 0 {
                pendingWrite.removeFirst(n)
                continue
            }
            if n < 0 && errno == EAGAIN {
                scheduleWriteSourceIfNeeded()
                return
            }
            // 진짜 에러(또는 0바이트 write) — 더 쓸 수 없으니 남은 데이터를 버리고 멈춘다.
            pendingWrite.removeAll()
            cancelWriteSourceIfNeeded()
            return
        }
        // pendingWrite를 전부 flush했다 — 더 이상 "쓰기 가능" 이벤트를 기다릴 필요가 없다.
        cancelWriteSourceIfNeeded()
    }

    /// 최초 EAGAIN에서만 생성해 즉시 resume하고, flush가 끝나면 cancel + nil로 되돌린다
    /// (다음 EAGAIN에서 다시 새로 만든다). suspend 상태의 소스를 cancel하면 크래시하므로
    /// "만들자마자 resume, 다 쓰면 cancel"이라는 균형을 항상 유지한다.
    private func scheduleWriteSourceIfNeeded() {
        guard writeSource == nil, masterFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.flushPendingWrite()
        }
        source.resume()
        writeSource = source
    }

    private func cancelWriteSourceIfNeeded() {
        guard let source = writeSource else { return }
        writeSource = nil
        source.cancel()
    }

    func resize(cols: UInt16, rows: UInt16) {
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            _ = cpty_set_winsize(self.masterFD, rows, cols)
        }
    }

    func terminate(force: Bool = false) {
        guard pid > 0, isRunning else { return }
        // tmux attach 클라이언트는 SIGHUP으로 자연스럽게 detach한다. Quick의
        // 직접 실행 Claude는 SIGHUP을 처리해 생존할 수 있어 SIGTERM이 필요하다.
        kill(pid, force ? SIGTERM : SIGHUP)
    }

    deinit {
        // fd는 readSource의 cancel handler가 닫는다 — 여기서 직접 close하지 않는다.
        // writeSource도 그 cancel handler 안에서 함께 정리되므로 별도로 취소할 필요가 없다.
        if pid > 0, isRunning { kill(pid, SIGHUP) }
        readSource?.cancel()
        exitSource?.cancel()
    }
}
