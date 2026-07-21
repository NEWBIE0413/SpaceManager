import Foundation

/// 최근 대화가 오간 Claude Code 세션 하나.
struct RecentClaudeSession: Identifiable, Equatable {
    let id: String          // 세션 uuid (transcript 파일명)
    let cwd: String         // 세션의 작업 디렉토리 (transcript의 cwd 필드)
    let name: String        // 표시용 — cwd 마지막 경로 요소
    let lastActivity: Date
    let snippet: String?    // 마지막 유저 메시지 한 줄 — "무슨 작업이었는지"의 단서
}

/// ~/.claude/projects/*/<uuid>.jsonl 의 mtime으로 "최근 대화가 오간" 세션을 찾는다.
///
/// transcript는 메시지가 오갈 때마다 append되므로 mtime이 곧 마지막 상호작용 시각이다.
/// 프로세스 목록이 아니라 파일 mtime을 보는 이유: 떠 있기만 하고 대화가 없는 세션은
/// "최근 작업"이 아니고, 반대로 CLI를 껐어도 방금까지 대화했다면 최근 작업이 맞다.
final class RecentActivityScanner: ObservableObject {
    @Published private(set) var sessions: [RecentClaudeSession] = []

    /// "최근"의 정의 — 지난 1시간
    static let activityWindow: TimeInterval = 3600
    /// 아일랜드가 소음이 되지 않도록 표시 개수 제한
    static let maxSessions = 8

    private let projectsDir: URL
    private var timer: Timer?
    private let queue = DispatchQueue(label: "SpaceManager.RecentActivity", qos: .utility)

    init(projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.projectsDir = projectsDir
    }

    func start() {
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func rescan() {
        let dir = projectsDir
        queue.async { [weak self] in
            let found = Self.scan(projectsDir: dir)
            DispatchQueue.main.async {
                guard let self, self.sessions != found else { return }
                self.sessions = found
            }
        }
    }

    // MARK: - 스캔

    static func scan(projectsDir: URL, now: Date = Date()) -> [RecentClaudeSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var recent: [(url: URL, mtime: Date)] = []
        let cutoff = now.addingTimeInterval(-activityWindow)
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }
                recent.append((file, mtime))
            }
        }

        // tail 파싱은 활성 파일에만 — 전체 스캔은 stat뿐이라 싸다
        let top = recent.sorted { $0.mtime > $1.mtime }.prefix(maxSessions)
        return top.compactMap { entry in
            let parsed = parseTail(of: entry.url)
            guard let cwd = parsed.cwd else { return nil }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let name = cwd == home ? "~" : URL(fileURLWithPath: cwd).lastPathComponent
            return RecentClaudeSession(
                id: entry.url.deletingPathExtension().lastPathComponent,
                cwd: cwd,
                name: name,
                lastActivity: entry.mtime,
                snippet: parsed.snippet
            )
        }
    }

    /// transcript 끝부분에서 cwd와 마지막 유저 메시지를 뽑는다.
    /// 파일이 수백 MB일 수 있으므로 마지막 128KB만 읽는다 — cwd는 거의 모든 라인에 있고,
    /// 유저 텍스트도 보통 그 안에 있다. 못 찾으면 스니펫 없이 표시한다 (best-effort).
    static func parseTail(of url: URL) -> (cwd: String?, snippet: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readLength = min(size, 131_072)
        try? handle.seek(toOffset: size - readLength)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var cwd: String?
        var snippet: String?
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if snippet == nil, let s = userText(from: obj) { snippet = s }
            if cwd != nil && snippet != nil { break }
        }
        return (cwd, snippet)
    }

    /// 유저가 직접 친 메시지만 스니펫으로 — 도구 결과·커맨드 메타(<command-…>)·
    /// 인터럽트 마커는 "무슨 작업이었는지"를 말해주지 않는다.
    private static func userText(from obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("Caveat:"),
              !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}
