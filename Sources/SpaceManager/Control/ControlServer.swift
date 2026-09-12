import Foundation

/// CLI가 보내는 한 요청. 한 연결에 JSON 한 줄, 응답 한 줄.
struct ControlRequest {
    let command: String
    let args: [String: Any]

    func string(_ key: String) -> String? {
        if let s = args[key] as? String { return s }
        if let n = args[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func bool(_ key: String) -> Bool? { args[key] as? Bool }
    func int(_ key: String) -> Int? {
        if let n = args[key] as? Int { return n }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }
}

enum ControlResponse {
    case ok(Any)
    case error(String)

    var json: [String: Any] {
        switch self {
        case .ok(let result): return ["ok": true, "result": result]
        case .error(let message): return ["ok": false, "error": message]
        }
    }
}

/// UNIX 도메인 소켓 제어 서버. 앱 안에서 돌며 `sm` CLI의 요청을 메인 스레드로 넘긴다.
///
/// 왜 소켓인가: 창별 AppState는 프로세스 안에만 있고, 상태 파일(window-states.json)을
/// 밖에서 고치면 실행 중인 앱과 어긋난다. CLI가 "앱 내 기능 전부"를 쓰려면 앱 자신이
/// 명령을 받아야 한다. 프로토콜은 줄 단위 JSON — 어떤 언어의 스크립트도 붙을 수 있다.
final class ControlServer {
    typealias Handler = (ControlRequest, @escaping (ControlResponse) -> Void) -> Void

    static let maxRequestBytes = 1 << 20

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "space-manager.control.accept", qos: .utility)

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)   // 이전 프로세스가 남긴 stale 소켓
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.system("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw ControlError.system("path too long", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); throw ControlError.system("bind", e) }
        chmod(path, 0o600)   // 같은 사용자만
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw ControlError.system("listen", e) }
        listenFD = fd
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        readLoop: while data.count < Self.maxRequestBytes {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.last == UInt8(ascii: "\n") { break readLoop }
        }
        let finish: (ControlResponse) -> Void = { response in
            var out = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data()
            out.append(UInt8(ascii: "\n"))
            out.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            close(client)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else {
            finish(.error("invalid request: expected {\"command\": ..., \"args\": {...}}"))
            return
        }
        let request = ControlRequest(command: command, args: obj["args"] as? [String: Any] ?? [:])
        DispatchQueue.main.async { [handler] in handler(request, finish) }
    }

    enum ControlError: Error, CustomStringConvertible {
        case system(String, Int32)
        var description: String {
            switch self { case .system(let what, let code): return "\(what): \(String(cString: strerror(code)))" }
        }
    }
}
