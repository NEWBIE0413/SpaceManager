import Foundation

/// 원격 호스트의 활동 요약(`~/.space-manager/remote/<host>/activity.json`)을 읽어
/// 로컬 스캐너가 쓰는 레코드로 바꾼다. 파일은 `scripts/remote-activity-mirror.sh`가
/// 주기적으로 갈아 끼운다 — 이 앱은 ssh를 직접 하지 않는다.
///
/// 원격 transcript는 로컬에 없으므로 "생성 중" 판정도 요약 안의 mtime으로 한다.
/// 두 머신의 시계가 어긋날 수 있어 원격 시각을 그대로 믿지 않고, 요약이 만들어진
/// 시각(generatedAt)과 로컬 파일의 mtime 차이를 스큐로 보정한다.
enum RemoteActivityMirror {
    struct Record: Equatable {
        let provider: AgentProvider
        let id: String
        let cwd: String
        let modified: Date
        let lastActivity: Date
        let snippet: String?
    }

    struct Snapshot: Equatable {
        let home: String
        let generatedAt: Date
        let records: [Record]
    }

    struct Result: Equatable {
        var records: [AgentActivityRecord] = []
        /// generatingIndex에 넣을 항목. 키는 로컬 transcript 경로와 겹치지 않도록 `remote/` 접두.
        var generating: [String: GeneratingActivityIndex.Entry] = [:]
    }

    /// 요약 파일이 이보다 오래됐으면 미러가 멈춘 것이다 — 원격이 꺼졌거나 ssh가 끊겼다.
    /// 그때는 "생성 중"을 보이지 않되, 24시간 창의 활동 점은 그대로 둔다(마지막으로 안 사실이므로).
    static let staleWindow: TimeInterval = 30

    static func parse(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let home = root["home"] as? String,
              let generated = root["generatedAt"] as? NSNumber,
              let rows = root["records"] as? [[String: Any]] else { return nil }
        let records = rows.compactMap { row -> Record? in
            guard let providerRaw = row["provider"] as? String, let provider = AgentProvider(rawValue: providerRaw),
                  let id = row["id"] as? String, let cwd = row["cwd"] as? String,
                  let mtime = row["mtime"] as? NSNumber, let last = row["lastActivity"] as? NSNumber else { return nil }
            return Record(provider: provider, id: id, cwd: cwd,
                          modified: Date(timeIntervalSince1970: mtime.doubleValue),
                          lastActivity: Date(timeIntervalSince1970: last.doubleValue),
                          snippet: row["snippet"] as? String)
        }
        return Snapshot(home: home, generatedAt: Date(timeIntervalSince1970: generated.doubleValue), records: records)
    }

    /// 원격 홈 아래 경로를 로컬 홈으로 옮긴다 (`/home/x/proj` → `/Users/x/proj`).
    /// TmuxBootstrap.remoteDirectory의 역방향 — 워크스페이스 rootPath와 같은 문자열이 되어야 점이 붙는다.
    static func localPath(forRemoteCwd cwd: String, remoteHome: String, localHome: String) -> String {
        let remote = remoteHome.hasSuffix("/") ? String(remoteHome.dropLast()) : remoteHome
        let local = localHome.hasSuffix("/") ? String(localHome.dropLast()) : localHome
        if cwd == remote { return local }
        if cwd.hasPrefix(remote + "/") { return local + cwd.dropFirst(remote.count) }
        return cwd
    }

    static func convert(_ snapshot: Snapshot, host: String, localHome: String,
                        fileModified: Date, now: Date = Date()) -> Result {
        var result = Result()
        let skew = fileModified.timeIntervalSince(snapshot.generatedAt)
        let fresh = now.timeIntervalSince(fileModified) <= staleWindow
        for record in snapshot.records {
            // 맥에서 복사해 간 transcript는 cwd가 로컬 홈 경로 그대로다. 원격 활동이 아니므로 뺀다 —
            // 안 그러면 복사 직후 24시간 동안 로컬 워크스페이스에 가짜 점이 붙는다.
            if snapshot.home != localHome, record.cwd == localHome || record.cwd.hasPrefix(localHome + "/") { continue }
            let cwd = localPath(forRemoteCwd: record.cwd, remoteHome: snapshot.home, localHome: localHome)
            let id = "\(host):\(record.provider.rawValue):\(record.id)"
            result.records.append(AgentActivityRecord(
                id: id, provider: record.provider, cwd: cwd, lastActivity: record.lastActivity,
                snippet: record.snippet, growingFile: nil, host: host
            ))
            if fresh {
                result.generating["remote/\(id)"] = .init(cwd: cwd, modified: record.modified.addingTimeInterval(skew))
            }
        }
        return result
    }

    /// `mirrorsDir/<host>/activity.json` 전부. 디렉토리 이름이 ssh 별칭이자 Workspace.remoteHost다.
    static func scan(mirrorsDir: URL, localHome: String = NSHomeDirectory(), now: Date = Date()) -> Result {
        let fm = FileManager.default
        guard let hosts = try? fm.contentsOfDirectory(at: mirrorsDir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return Result() }
        var combined = Result()
        for hostDir in hosts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = hostDir.appendingPathComponent("activity.json")
            guard let signature = FileSignature.read(file),
                  let data = try? Data(contentsOf: file),
                  let snapshot = parse(data) else { continue }
            let part = convert(snapshot, host: hostDir.lastPathComponent, localHome: localHome,
                               fileModified: signature.modified, now: now)
            combined.records += part.records
            combined.generating.merge(part.generating) { _, new in new }
        }
        return combined
    }
}
