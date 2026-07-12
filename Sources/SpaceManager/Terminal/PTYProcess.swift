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

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                self.onOutput?(Data(bytes: buffer, count: n))
            } else {
                self.readSource?.cancel()
            }
        }
        readSource.resume()
        self.readSource = readSource

        let exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: ioQueue)
        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
            self.isRunning = false
            self.readSource?.cancel()
            self.exitSource?.cancel()
            self.onExit?(code)
        }
        exitSource.resume()
        self.exitSource = exitSource
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
        readSource?.cancel()
        exitSource?.cancel()
        if masterFD >= 0 { close(masterFD) }
        if pid > 0, isRunning { kill(pid, SIGHUP) }
    }
}
