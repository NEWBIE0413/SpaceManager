import Foundation

/// 최근 대화가 오간 에이전트 세션 하나.
struct RecentAgentSession: Identifiable, Equatable {
    let id: String          // 세션 uuid (transcript 파일명)
    let provider: AgentProvider
    let cwd: String         // 세션의 작업 디렉토리 (transcript의 cwd 필드)
    let name: String        // 표시용 — cwd 마지막 경로 요소
    let lastActivity: Date
    let snippet: String?    // 마지막 유저 메시지 한 줄 — "무슨 작업이었는지"의 단서
    var host: String? = nil // 원격 머신에서 돈 세션이면 ssh 별칭 (cwd는 이미 로컬 경로로 옮겨져 있다)
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
/// 원격 워크스페이스의 활동은 `~/.space-manager/remote/<host>/activity.json`(미러 스크립트가
/// 5초마다 갈아 끼우는 요약)에서 온다. 그 파일의 교체는 같은 FSEvents로 잡아 요약만 다시
/// 읽고, 로컬 transcript 탐색은 건드리지 않는다.
///
/// 파일 변경은 FSEvents로 감지하고 알려진 변경 파일만 stat한다. 생성 표시의
/// 만료는 메모리상의 mtime과 단발 타이머로 처리한다. 30초 재탐색은 유실된 이벤트와
/// 새 기록을 보정하며, 바뀌지 않은 파일의 파싱 결과는 재사용한다.
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
    /// 마지막 append 이후 이 시간 동안 생성 중으로 본다.
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
    private let remoteMirrorsDir: URL
    private var discoveryTimer: Timer?
    private var expirationTimer: Timer?
    private let watcher = DirectoryWatcher()
    private let visibilityID = UUID()
    private var started = false
    private var windowOwners = Set<UUID>()
    var isStarted: Bool { started }
    private(set) var isVisible = false
    private(set) var isScanning = false
    private var rescanPending = false
    private var discoveryScheduled: DispatchWorkItem?
    private var unresolvedPaths = Set<String>()
    private var trackedByPath: [String: TrackedTranscript] = [:]
    private var generatingIndex = GeneratingActivityIndex()
    /// 마지막 로컬 탐색 결과와 마지막 원격 요약 — 둘 중 하나만 바뀌어도 합쳐서 다시 게시한다
    private var localResult = ScanResult()
    private var remoteResult = RemoteActivityMirror.Result()
    private var remoteReloadPending = false
    private var visibilityGeneration = 0
    private(set) var fileStatCount = 0
    private(set) var metadataLoadCount = 0
    private var tailCache = FileMetadataCache<Tail>()
    private var sourceCache = AgentActivitySources.Cache()
    private let queue = DispatchQueue(label: "SpaceManager.RecentActivity", qos: .utility)
    /// transcript 파일의 cwd는 불변이므로 한 번 읽으면 캐시한다 (queue 위에서만 접근)
    private var cwdCache: [String: String] = [:]

    init(
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        codexSessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        geminiDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini"),
        remoteMirrorsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".space-manager/remote")
    ) {
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
        self.geminiDir = geminiDir
        self.remoteMirrorsDir = remoteMirrorsDir
    }

    func start() {
        guard !started else { return }
        started = true
        AppResourcePolicy.shared.observe(visibilityID) { [weak self] in self?.setVisible($0) }
    }

    func stop() {
        started = false
        AppResourcePolicy.shared.removeObserver(visibilityID)
        setVisible(false)
    }

    func start(owner: UUID) {
        windowOwners.insert(owner)
        start()
    }

    func stop(owner: UUID) {
        windowOwners.remove(owner)
        if windowOwners.isEmpty { stop() }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        visibilityGeneration += 1
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        discoveryScheduled?.cancel()
        discoveryScheduled = nil
        rescanPending = false
        watcher.stop()
        guard visible else { return }
        startWatcher()
        rescan()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.unresolvedPaths.removeAll(keepingCapacity: true)
            self.startWatcher()
            self.rescan()
        }
        discoveryTimer?.tolerance = 5
    }

    private func startWatcher() {
        watcher.onPathsChange = { [weak self] paths, fullRescan in
            self?.filesChanged(paths, fullRescan: fullRescan)
        }
        watcher.start(paths: [projectsDir.path, codexSessionsDir.path, geminiDir.path, remoteMirrorsDir.path])
    }

    func rescan() {
        guard !isScanning else { rescanPending = true; return }
        isScanning = true
        let generation = visibilityGeneration
        queue.async { [weak self] in
            guard let self else { return }
            var result = Self.scan(projectsDir: self.projectsDir, cwdCache: &self.cwdCache, tailCache: &self.tailCache)
            let records = AgentActivitySources.scanCodex(sessionsDir: self.codexSessionsDir, cache: &self.sourceCache)
                + AgentActivitySources.scanGemini(geminiDir: self.geminiDir, cache: &self.sourceCache)
            Self.merge(records: records, into: &result)
            let remote = RemoteActivityMirror.scan(mirrorsDir: self.remoteMirrorsDir)
            var index = GeneratingActivityIndex()
            var tracked: [String: TrackedTranscript] = [:]
            for transcript in result.trackedTranscripts {
                let path = transcript.url.resolvingSymlinksInPath().path
                tracked[path] = transcript
                if let signature = FileSignature.read(transcript.url) {
                    index.entries[path] = .init(cwd: transcript.cwd, modified: signature.modified)
                }
            }
            let loads = self.tailCache.loadCount + self.sourceCache.loadCount
            DispatchQueue.main.async {
                self.isScanning = false
                if generation == self.visibilityGeneration {
                    self.localResult = result
                    self.remoteResult = remote
                    self.trackedByPath = tracked
                    self.generatingIndex = index
                    self.fileStatCount += result.trackedTranscripts.count
                    self.metadataLoadCount = loads
                    self.publishCombined()
                }
                if self.rescanPending {
                    self.rescanPending = false
                    self.rescan()
                }
            }
        }
    }

    /// 원격 요약만 다시 읽는다 — 미러 파일이 5초마다 바뀌므로 그때마다 로컬 전체 탐색을
    /// 돌리면 원격 지원이 로컬 비용을 키운다. 로컬 결과는 마지막 것을 그대로 쓴다.
    private func reloadRemote() {
        guard !remoteReloadPending else { return }
        remoteReloadPending = true
        let generation = visibilityGeneration
        queue.async { [weak self] in
            guard let self else { return }
            let remote = RemoteActivityMirror.scan(mirrorsDir: self.remoteMirrorsDir)
            DispatchQueue.main.async {
                self.remoteReloadPending = false
                guard self.isVisible, self.visibilityGeneration == generation else { return }
                self.remoteResult = remote
                self.publishCombined()
            }
        }
    }

    /// 로컬 탐색 + 원격 요약을 합쳐 게시한다. 아일랜드 순서·개수 제한은 합친 뒤에 적용한다.
    private func publishCombined() {
        var result = localResult
        Self.merge(records: remoteResult.records, into: &result)
        if sessions != result.sessions { sessions = result.sessions }
        if workspaceActivity != result.activityByCwd { workspaceActivity = result.activityByCwd }
        generatingIndex.entries = generatingIndex.entries.filter { !$0.key.hasPrefix("remote/") }
            .merging(remoteResult.generating) { _, new in new }
        publishGenerating()
    }

    func filesChanged(_ paths: Set<String>, fullRescan: Bool = false) {
        guard isVisible else { return }
        if fullRescan { startWatcher(); scheduleDiscovery() }
        let normalized = Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let mirrorRoot = remoteMirrorsDir.resolvingSymlinksInPath().path + "/"
        if normalized.contains(where: { $0.hasPrefix(mirrorRoot) }) { reloadRemote() }
        let changed = normalized.compactMap { path in trackedByPath[path].map { (path, $0) } }
        // Unknown/new transcripts get one early discovery. A record that has not
        // written its identity yet is retried by the 30-second reconciliation.
        var foundNewPath = false
        for path in normalized where trackedByPath[path] == nil && (path.hasSuffix(".jsonl") || path.hasSuffix(".json")) {
            if unresolvedPaths.insert(path).inserted { foundNewPath = true }
        }
        if foundNewPath { scheduleDiscovery() }
        guard !changed.isEmpty else { return }
        let generation = visibilityGeneration
        queue.async { [weak self] in
            let updates = changed.map { path, transcript in
                (path, transcript.cwd, FileSignature.read(transcript.url)?.modified)
            }
            DispatchQueue.main.async {
                guard let self, self.isVisible, self.visibilityGeneration == generation else { return }
                self.fileStatCount += updates.count
                for (path, cwd, modified) in updates {
                    self.generatingIndex.entries[path] = modified.map { .init(cwd: cwd, modified: $0) }
                }
                self.publishGenerating()
            }
        }
    }

    private func scheduleDiscovery() {
        guard discoveryScheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.discoveryScheduled = nil
            if self.isVisible { self.rescan() }
        }
        discoveryScheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func publishGenerating() {
        let now = Date()
        let generating = generatingIndex.directories(now: now)
        if generatingDirectories != generating { generatingDirectories = generating }
        expirationTimer?.invalidate()
        expirationTimer = nil
        guard isVisible, let expiration = generatingIndex.nextExpiration(now: now) else { return }
        expirationTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, expiration.timeIntervalSince(now) + 0.01),
            repeats: false) { [weak self] _ in self?.publishGenerating() }
    }

    // MARK: - 스캔

    typealias Tail = (cwd: String?, snippet: String?, lastActivity: Date?)

    static func scan(projectsDir: URL, cwdCache: inout [String: String], now: Date = Date()) -> ScanResult {
        var tailCache = FileMetadataCache<Tail>()
        return scan(projectsDir: projectsDir, cwdCache: &cwdCache, tailCache: &tailCache, now: now)
    }

    static func scan(projectsDir: URL, cwdCache: inout [String: String],
                     tailCache: inout FileMetadataCache<Tail>, now: Date = Date()) -> ScanResult {
        tailCache.beginPass()
        defer { tailCache.endPass() }
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { cwdCache.removeAll(); return ScanResult() }

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
            let parsed = tailCache.value(for: entry.url) { parseTail(of: entry.url) } ?? (nil, nil, nil)
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

        let retained = Set(candidates.map { $0.url.path })
        cwdCache = cwdCache.filter { retained.contains($0.key) }

        // 1시간 창 상위 8개 (아일랜드)
        let islandCutoff = now.addingTimeInterval(-islandWindow)
        let top = recent.filter { $0.activity > islandCutoff }
            .sorted { $0.activity > $1.activity }
            .prefix(maxSessions)
        result.sessions = top.compactMap { entry in
            guard let cwd = entry.parsed.cwd ?? cwdCache[entry.url.path] else { return nil }
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
                    snippet: record.snippet,
                    host: record.host
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
    static func parseTail(of url: URL) -> Tail {
        guard let data = TranscriptJSON.tail(url) else { return (nil, nil, nil) }
        var cwd: String?
        var snippet: String?
        var lastActivity: Date?
        for line in data.split(separator: 10).reversed() {
            guard let obj = TranscriptJSON.object(Data(line)) else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if snippet == nil, let text = userText(from: obj) { snippet = String(text.prefix(240)) }
            if lastActivity == nil, let raw = obj["timestamp"] as? String {
                lastActivity = TranscriptJSON.timestamp(raw)
            }
            if cwd != nil && snippet != nil && lastActivity != nil { break }
        }
        return (cwd, snippet, lastActivity)
    }

    /// 유저가 직접 친 메시지만 스니펫으로 — 도구 결과·커맨드 메타(<command-…>)·
    /// 인터럽트 마커는 "무슨 작업이었는지"를 말해주지 않는다.
    static func userText(from obj: [String: Any]) -> String? {
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
