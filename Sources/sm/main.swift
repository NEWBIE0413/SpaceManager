import Foundation

// sm — SpaceManager CLI. 앱의 제어 소켓(~/.space-manager/control.sock)에 JSON 한 줄을 보내고
// 응답을 사람이 읽기 좋게, 또는 --json으로 그대로 출력한다. 앱이 안 떠 있으면 띄우고 기다린다.

let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".space-manager/control.sock")
let bundleID = "com.spacemanager.app"

let usage = """
sm — SpaceManager를 터미널에서 조작한다

  sm windows                          창 목록
  sm window new [--quick]             새 창 (워크스페이스/Quick)
  sm window focus|close <win>         창 앞으로/닫기
  sm window appearance <win> <light|dark|system>

  sm ws [list]                        워크스페이스 목록 (모든 창)
  sm ws add <path> [--name N] [--host arch|local]  실행 위치를 지정해 추가
  sm ws select|delete <ws>            선택(창 앞으로)/삭제
  sm ws rename <ws> <name>            이름 변경 (빈 문자열이면 폴더명)
  sm ws tmux-name <ws> <name>         tmux 세션명
  sm ws remote <ws> <host|none>       원격 호스트 (ssh 별칭) — tmux를 그 머신에서
  sm ws move <ws> <index>             순서 이동
  sm project add|remove <ws> <path>   추가 프로젝트 폴더

  sm tabs [ws]                        탭 목록
  sm tab shell|tmux [ws]              탭 추가
  sm tab select|close <tab>           탭 선택/닫기
  sm tab reconnect <tab>              끊어진 연결 재시도 (실행 중 세션 유지)
  sm tab next|prev

  sm quick [list] [-n N]              최근 Claude 대화
  sm quick new [--model M] [--effort E] [--proxy] [prompt…]
  sm quick resume <session-id>
  sm quick home

  sm activity                         에이전트 활동 (transcript 기반)
  sm state                            window-states.json 덤프
  sm ping

옵션: --json (원본 JSON), -w/--window <id|index|front>, --no-focus
<ws>는 이름 / tmux 세션명 / 경로 / id 접두사, <tab>은 이름 / 인덱스 / id 접두사, <win>은 index / id 접두사 / front
"""

struct CLIError: Error { let message: String }

func send(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
    if !FileManager.default.fileExists(atPath: socketPath) {
        FileHandle.standardError.write("sm: SpaceManager not running — launching…\n".data(using: .utf8)!)
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-g", "-b", bundleID]
        try open.run(); open.waitUntilExit()
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: socketPath) && Date() < deadline { usleep(200_000) }
        usleep(300_000)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError(message: "socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard rc == 0 else { throw CLIError(message: "cannot connect to \(socketPath): \(String(cString: strerror(errno))) — is SpaceManager (with control server) running?") }
    var payload = try JSONSerialization.data(withJSONObject: ["command": command, "args": args])
    payload.append(UInt8(ascii: "\n"))
    payload.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress!, raw.count) }
    var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n); if data.last == UInt8(ascii: "\n") { break } }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError(message: "bad response") }
    if obj["ok"] as? Bool != true { throw CLIError(message: obj["error"] as? String ?? "unknown error") }
    return obj
}

// MARK: - 인자 파싱

var argv = Array(CommandLine.arguments.dropFirst())
var wantJSON = false
var windowArg: String?
var noFocus = false
var positional: [String] = []
var flags: [String: String] = [:]
var i = 0
while i < argv.count {
    let a = argv[i]
    switch a {
    case "--json": wantJSON = true
    case "--no-focus": noFocus = true
    case "-w", "--window": i += 1; windowArg = i < argv.count ? argv[i] : nil
    case "--quick", "--proxy": flags[String(a.dropFirst(2))] = "true"
    case "--name", "--host", "--model", "--effort", "-n", "--limit":
        i += 1; flags[a.hasPrefix("--") ? String(a.dropFirst(2)) : "limit"] = i < argv.count ? argv[i] : ""
    case "-h", "--help", "help": print(usage); exit(0)
    default: positional.append(a)
    }
    i += 1
}
guard let group = positional.first else { print(usage); exit(1) }
let sub = positional.count > 1 ? positional[1] : nil
let rest = Array(positional.dropFirst(2))
var args: [String: Any] = [:]
if let windowArg { args["window"] = windowArg }
if noFocus { args["focus"] = false }

func need(_ n: Int, _ what: String) throws -> [String] {
    guard rest.count >= n else { throw CLIError(message: "usage: \(what)") }
    return rest
}

let command: String
do {
    switch (group, sub) {
    case ("ping", _): command = "ping"
    case ("windows", _): command = "windows.list"
    case ("window", "new"): command = "window.new"; if flags["quick"] != nil { args["kind"] = "quick" }
    case ("window", "focus"), ("window", "close"):
        command = "window.\(sub!)"; args["window"] = try need(1, "sm window \(sub!) <win>")[0]
    case ("window", "appearance"):
        let a = try need(2, "sm window appearance <win> <light|dark|system>"); command = "window.appearance"; args["window"] = a[0]; args["value"] = a[1]
    case ("ws", nil), ("ws", "list"), ("workspaces", _): command = "ws.list"
    case ("ws", "add"):
        command = "ws.add"; args["path"] = try need(1, "sm ws add <path> [--host arch|local]")[0]
        if let n = flags["name"] { args["name"] = n }
        if let host = flags["host"] { args["host"] = host }
    case ("ws", "select"), ("ws", "delete"): command = "ws.\(sub!)"; args["ws"] = try need(1, "sm ws \(sub!) <ws>")[0]
    case ("ws", "rename"): let a = try need(1, "sm ws rename <ws> <name>"); command = "ws.rename"; args["ws"] = a[0]; args["name"] = a.count > 1 ? a[1] : ""
    case ("ws", "tmux-name"): let a = try need(1, "sm ws tmux-name <ws> <name>"); command = "ws.tmuxName"; args["ws"] = a[0]; args["name"] = a.count > 1 ? a[1] : ""
    case ("ws", "remote"): let a = try need(2, "sm ws remote <ws> <host|none>"); command = "ws.remote"; args["ws"] = a[0]; args["host"] = a[1]
    case ("ws", "move"): let a = try need(2, "sm ws move <ws> <index>"); command = "ws.move"; args["ws"] = a[0]; args["index"] = Int(a[1]) ?? 0
    case ("project", "add"), ("project", "remove"):
        let a = try need(2, "sm project \(sub!) <ws> <path>"); command = "project.\(sub!)"; args["ws"] = a[0]; args["path"] = a[1]
    case ("tabs", _): command = "tab.list"; if let s = sub { args["ws"] = s }
    case ("tab", "list"): command = "tab.list"; if let w = rest.first { args["ws"] = w }
    case ("tab", "shell"), ("tab", "tmux"): command = "tab.\(sub!)"; if let w = rest.first { args["ws"] = w }
    case ("tab", "select"), ("tab", "close"), ("tab", "reconnect"): command = "tab.\(sub!)"; args["tab"] = try need(1, "sm tab \(sub!) <tab>")[0]
    case ("tab", "next"), ("tab", "prev"): command = "tab.\(sub!)"
    case ("quick", nil), ("quick", "list"): command = "quick.list"; args["limit"] = Int(flags["limit"] ?? "30") ?? 30
    case ("quick", "new"):
        command = "quick.new"; let prompt = rest.joined(separator: " "); if !prompt.isEmpty { args["prompt"] = prompt }
        if let m = flags["model"] { args["model"] = m }; if let e = flags["effort"] { args["effort"] = e }; if flags["proxy"] != nil { args["proxy"] = true }
    case ("quick", "resume"): command = "quick.resume"; args["id"] = try need(1, "sm quick resume <session-id>")[0]
    case ("quick", "home"): command = "quick.home"
    case ("activity", _): command = "activity.list"
    case ("state", _): command = "state.dump"
    default: throw CLIError(message: "unknown command: \(positional.joined(separator: " "))\n\n\(usage)")
    }
    let response = try send(command, args)
    let result = response["result"] ?? NSNull()
    if wantJSON {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(render(command: command, result: result))
    }
} catch let error as CLIError {
    FileHandle.standardError.write("sm: \(error.message)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("sm: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 사람이 읽는 출력

func render(command: String, result: Any) -> String {
    func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "(none)" }
        var widths = Array(repeating: 0, count: first.count)
        for row in rows { for (i, c) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
        return rows.map { row in row.enumerated().map { i, c in i == row.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ") }.joined(separator: "\n")
    }
    func short(_ id: Any?) -> String { String((id as? String ?? "").prefix(8)).lowercased() }
    // NSNumber는 Bool로도 브리징되므로 CFBoolean인지 먼저 가려야 0/1이 yes/no로 둔갑하지 않는다
    func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "yes" : "" }
            return n.stringValue
        }
        return ""
    }
    func home(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    switch command {
    case "windows.list":
        let rows = (result as? [[String: Any]] ?? []).enumerated().map { i, w in
            [String(i), short(w["id"]), str(w["kind"]), str(w["isKey"]) == "yes" ? "*" : "", str(w["selectedWorkspace"]), "\(str(w["workspaceCount"])) ws", "\(str(w["tabCount"])) tabs", str(w["appearance"])]
        }
        return table([["#", "id", "kind", "key", "selected", "", "", "look"]] + rows)
    case "ws.list", "ws.move":
        let rows = (result as? [[String: Any]] ?? []).map { w in
            [str(w["selected"]) == "yes" ? "*" : "", str(w["name"]), str(w["tmuxSession"]), str(w["remoteHost"]).isEmpty ? "local" : "@" + str(w["remoteHost"]), home(str(w["rootPath"])), short(w["window"])]
        }
        return table([["", "name", "tmux", "host", "path", "win"]] + rows)
    case "tab.list":
        let rows = (result as? [[String: Any]] ?? []).enumerated().map { i, t in
            [String(i), str(t["selected"]) == "yes" ? "*" : "", str(t["kind"]), str(t["name"]), str(t["remoteHost"]).isEmpty ? "" : "@" + str(t["remoteHost"]), str(t["running"]) == "yes" ? "running" : "idle", short(t["id"])]
        }
        return table([["#", "", "kind", "name", "host", "state", "id"]] + rows)
    case "quick.list":
        let rows = (result as? [[String: Any]] ?? []).map { c in [str(c["id"]), String(str(c["modifiedAt"]).prefix(16)), str(c["title"])] }
        return table([["session-id", "modified", "title"]] + rows)
    case "activity.list":
        guard let dict = result as? [String: Any] else { return "\(result)" }
        let rows = (dict["sessions"] as? [[String: Any]] ?? []).map { s in [str(s["provider"]), String(str(s["lastActivity"]).prefix(16)), home(str(s["cwd"])), String(str(s["snippet"]).prefix(60))] }
        let generating = (dict["generating"] as? [String] ?? []).map(home)
        return table([["agent", "last", "cwd", "last prompt"]] + rows) + (generating.isEmpty ? "" : "\n\ngenerating: " + generating.joined(separator: ", "))
    default:
        if let dict = result as? [String: Any] {
            return dict.keys.sorted().map { k in "\(k): \(str(dict[k]).isEmpty ? "\(dict[k] ?? "")" : str(dict[k]))" }.joined(separator: "\n")
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { return String(decoding: data, as: UTF8.self) }
        return "\(result)"
    }
}
