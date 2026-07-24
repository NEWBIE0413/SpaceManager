import Foundation

/// 최근 대화가 오간 에이전트 세션 하나.
struct RecentAgentSession: Identifiable, Equatable {
    let id: String          // 세션 uuid (transcript 파일명)
    let provider: AgentProvider
    let cwd: String         // 세션의 작업 디렉토리 (transcript의 cwd 필드)
    let name: String        // 표시용 — cwd 마지막 경로 요소
    let lastActivity: Date
    let snippet: String?    // 마지막 유저 메시지 한 줄 — "무슨 작업이었는지"의 단서
}

/// ~/.claude/projects/*/<uuid>.jsonl 의 mtime으로 "최근 대화가 오간" 세션을 찾는다.
///
/// transcript는 메시지가 오갈 때마다 append된다. 생성 중 감지는 빠른 stat(mtime)을,
/// 최근 대화 시각은 JSONL 내부 이벤트 timestamp를 쓴다. Claude의 유지보수 작업이 여러
/// transcript의 mtime을 한꺼번에 만지는 경우에도 과거 대화가 전부 "방금"으로 뜨지 않는다.
///
/// 한 번의 스캔이 두 소비자를 먹인다:
/// - 아일랜드: 지난 1시간, 상위 8개, 스니펫 포함
/// - 사이드바 활동 점: 지난 24시간, cwd별 마지막 대화 시각 (진하기 계산용)
///
/// 생성 중 신호는 별도의 빠른 경로가 맡는다. 전체 디렉토리 탐색은 30초마다 하되,
/// 거기서 찾은 24시간 내 transcript만 2초마다 stat한다. 최근 4초 안에 mtime이
/// 갱신된 cwd를 "모델이 지금 응답을 생성 중"으로 본다.
final class RecentActivityScanner: ObservableObject {
    /// 모든 창이 같은 데이터를 보므로 하나만 돈다
    static let shared = RecentActivityScanner()

    @Published private(set) var sessions: [RecentAgentSession] = []
    /// cwd → 마지막 대화 시각 (24시간 창)
    @Published private(set) var workspaceActivity: [String: Date] = [:]
    /// 지금 transcript가 자라고 있는 cwd들
    @Published private(set) var generatingDirectories: Set<String> = []

    /// 아일랜드의 "최근" — 지난 1시간
    static let islandWindow: TimeInterval = 3600
    /// 사이드바 점의 "최근" — 지난 24시간
    static let dotWindow: TimeInterval = 86400
    /// 아일랜드가 소음이 되지 않도록 표시 개수 제한
    static let maxSessions = 8
    /// 알려진 transcript만 stat하는 빠른 폴 간격
    static let generatingPollInterval: TimeInterval = 2
    /// 마지막 append 이후 이 시간 동안 생성 중으로 본다. 폴 간격을 합쳐 최대 약 6초 내 해제.
    static let generatingWindow: TimeInterval = 4

    struct TrackedTranscript: Equatable {
        let url: URL
        let cwd: String
    }

    struct ScanResult: Equatable {
        var sessions: [RecentAgentSession] = []
        var activityByCwd: [String: Date] = [:]
        var trackedTranscripts: [TrackedTranscript] = []
    }

    private let projectsDir: URL
    private let codexSessionsDir: URL
    private let geminiDir: URL
    private var discoveryTimer: Timer?
    private var generatingTimer: Timer?
    private let queue = DispatchQueue(label: "SpaceManager.RecentActivity", qos: .utility)
    /// transcript 파일의 cwd는 불변이므로 한 번 읽으면 캐시한다 (queue 위에서만 접근)
    private var cwdCache: [String: String] = [:]
    /// 최근 전체 탐색에서 찾은 24시간 내 transcript (queue 위에서만 접근)
    private var trackedTranscripts: [TrackedTranscript] = []

    init(
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        codexSessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        geminiDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    ) {
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
        self.geminiDir = geminiDir
    }

    func start() {
        guard discoveryTimer == nil, generatingTimer == nil else { return }
        rescan()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rescan()
        }
        generatingTimer = Timer.scheduledTimer(withTimeInterval: Self.generatingPollInterval, repeats: true) { [weak self] _ in
            self?.pollGeneratingDirectories()
        }
    }

    func stop() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        generatingTimer?.invalidate()
        generatingTimer = nil
    }

    func rescan() {
        let dir = projectsDir
        let codexDir = codexSessionsDir
        let geminiRoot = geminiDir
        queue.async { [weak self] in
            guard let self else { return }
            var result = Self.scan(projectsDir: dir, cwdCache: &self.cwdCache)
            let records = AgentActivitySources.scanCodex(sessionsDir: codexDir)
                + AgentActivitySources.scanGemini(geminiDir: geminiRoot)
            Self.merge(records: records, into: &result)
            self.trackedTranscripts = result.trackedTranscripts
            let generating = Self.findGeneratingDirectories(in: result.trackedTranscripts)
            DispatchQueue.main.async {
                if self.sessions != result.sessions { self.sessions = result.sessions }
                if self.workspaceActivity != result.activityByCwd { self.workspaceActivity = result.activityByCwd }
                if self.generatingDirectories != generating { self.generatingDirectories = generating }
            }
        }
    }

    private func pollGeneratingDirectories() {
        queue.async { [weak self] in
            guard let self else { return }
            let generating = Self.findGeneratingDirectories(in: self.trackedTranscripts)
            DispatchQueue.main.async {
                if self.generatingDirectories != generating {
                    self.generatingDirectories = generating
                }
            }
        }
    }

    // MARK: - 스캔

    static func scan(projectsDir: URL, cwdCache: inout [String: String], now: Date = Date()) -> ScanResult {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return ScanResult() }

        var candidates: [(url: URL, mtime: Date)] = []
        let dotCutoff = now.addingTimeInterval(-dotWindow)
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > dotCutoff else { continue }
                candidates.append((file, mtime))
            }
        }

        var result = ScanResult()
        var recent: [(url: URL, activity: Date, parsed: (cwd: String?, snippet: String?, lastActivity: Date?))] = []

        // mtime은 "내용이 바뀌었을 가능성"을 좁히는 1차 필터일 뿐이다. 실제 최근성은
        // transcript 내부 마지막 이벤트 timestamp로 판정한다. timestamp가 없는 레거시/
        // 테스트 transcript만 mtime으로 폴백한다.
        for entry in candidates {
            let parsed = parseTail(of: entry.url)
            let activity = parsed.lastActivity ?? entry.mtime
            guard activity > dotCutoff else { continue }
            let key = entry.url.path
            let cwd = parsed.cwd ?? cwdCache[key]
            guard let cwd else { continue }
            cwdCache[key] = cwd
            result.activityByCwd[cwd] = max(result.activityByCwd[cwd] ?? .distantPast, activity)
            result.trackedTranscripts.append(TrackedTranscript(url: entry.url, cwd: cwd))
            recent.append((entry.url, activity, parsed))
        }

        // 1시간 창 상위 8개만 스니펫까지 파싱 (아일랜드)
        let islandCutoff = now.addingTimeInterval(-islandWindow)
        let top = recent.filter { $0.activity > islandCutoff }
            .sorted { $0.activity > $1.activity }
            .prefix(maxSessions)
        result.sessions = top.compactMap { entry in
            guard let cwd = entry.parsed.cwd else { return nil }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let name = cwd == home ? "~" : URL(fileURLWithPath: cwd).lastPathComponent
            return RecentAgentSession(
                id: "claude:\(entry.url.deletingPathExtension().lastPathComponent)",
                provider: .claude,
                cwd: cwd,
                name: name,
                lastActivity: entry.activity,
                snippet: entry.parsed.snippet
            )
        }
        return result
    }

    static func merge(records: [AgentActivityRecord], into result: inout ScanResult, now: Date = Date()) {
        let islandCutoff = now.addingTimeInterval(-islandWindow)
        for record in records {
            result.activityByCwd[record.cwd] = max(
                result.activityByCwd[record.cwd] ?? .distantPast,
                record.lastActivity
            )
            if let file = record.growingFile {
                result.trackedTranscripts.append(TrackedTranscript(url: file, cwd: record.cwd))
            }
            if record.lastActivity > islandCutoff {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                result.sessions.append(RecentAgentSession(
                    id: record.id,
                    provider: record.provider,
                    cwd: record.cwd,
                    name: record.cwd == home ? "~" : URL(fileURLWithPath: record.cwd).lastPathComponent,
                    lastActivity: record.lastActivity,
                    snippet: record.snippet
                ))
            }
        }
        result.sessions = Array(result.sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(maxSessions))
    }

    /// 전체 탐색에서 이미 확인한 transcript만 stat하는 빠른 경로.
    /// tmux 화면·프로세스 상태는 보지 않으므로 유휴 TUI나 dev server에는 반응하지 않는다.
    static func findGeneratingDirectories(
        in transcripts: [TrackedTranscript],
        now: Date = Date()
    ) -> Set<String> {
        var result = Set<String>()
        for transcript in transcripts {
            // URLResourceValues는 같은 URL의 속성을 캐시할 수 있어 빠른 폴 경로에 부적합하다.
            // 매번 실제 stat을 수행해 append와 삭제를 즉시 관측한다.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.url.path),
                  let mtime = attributes[.modificationDate] as? Date else { continue }
            let age = now.timeIntervalSince(mtime)
            if age >= 0, age <= generatingWindow {
                result.insert(transcript.cwd)
            }
        }
        return result
    }

    /// transcript 끝부분에서 cwd와 마지막 유저 메시지를 뽑는다.
    /// 파일이 수백 MB일 수 있으므로 마지막 128KB만 읽는다 — cwd는 거의 모든 라인에 있고,
    /// 유저 텍스트도 보통 그 안에 있다. 못 찾으면 스니펫 없이 표시한다 (best-effort).
    static func parseTail(of url: URL) -> (cwd: String?, snippet: String?, lastActivity: Date?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readLength = min(size, 131_072)
        try? handle.seek(toOffset: size - readLength)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil, nil) }

        var cwd: String?
        var snippet: String?
        var lastActivity: Date?
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if snippet == nil, let s = userText(from: obj) { snippet = s }
            if lastActivity == nil, let raw = obj["timestamp"] as? String {
                lastActivity = parseTimestamp(raw)
            }
            if cwd != nil && snippet != nil && lastActivity != nil { break }
        }
        return (cwd, snippet, lastActivity)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
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
