import Foundation

struct QuickConversation: Identifiable, Equatable {
    let id: String          // transcript 파일명의 UUID = ccv -ry 인자
    let title: String
    let aiTitle: String?
    let modifiedAt: Date
    let transcriptURL: URL
}

/// Metadata-only, demand-paged recent conversations shared by all windows.
final class QuickConversationScanner: ObservableObject {
    static let shared = QuickConversationScanner()
    static let refreshInterval: TimeInterval = 30
    static let pageSize = 30

    @Published private(set) var conversations: [QuickConversation] = []
    @Published private(set) var aiTitlesBySessionId: [String: String] = [:]
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    private(set) var metadataBytesRead = 0
    private var requestedCount = pageSize
    private var trackedSessions: [UUID: String] = [:]
    private var rescanPending = false
    private var titleIndex = TranscriptTitleIndex()
    private let transcriptsDirectory: URL
    private let queue = DispatchQueue(label: "SpaceManager.QuickConversations", qos: .utility)
    private var timer: Timer?
    private let watcher = DirectoryWatcher()
    private let visibilityID = UUID()
    private var started = false
    private var windowOwners = Set<UUID>()
    var isStarted: Bool { started }
    private var isVisible = false
    private var refreshScheduled: DispatchWorkItem?

    init(transcriptsDirectory: URL = QuickConversationScanner.defaultTranscriptsDirectory()) {
        self.transcriptsDirectory = transcriptsDirectory
    }

    static func defaultTranscriptsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoded = QuickSessionPolicy.workingDirectory.replacingOccurrences(of: "/", with: "-")
        return home.appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
    }

    func start() {
        guard !started else { return }
        started = true
        AppResourcePolicy.shared.observe(visibilityID) { [weak self] visible in
            self?.setVisible(visible)
        }
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
        stopIfUnused()
    }

    private func stopIfUnused() {
        if windowOwners.isEmpty && trackedSessions.isEmpty { stop() }
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        timer?.invalidate()
        timer = nil
        watcher.stop()
        refreshScheduled?.cancel()
        refreshScheduled = nil
        rescanPending = false
        guard visible else { return }
        startWatcher()
        rescan()
        // Reconcile missed events, newly created roots and removed transcripts.
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.startWatcher()
            self?.rescan()
        }
        timer?.tolerance = 5
    }

    private func startWatcher() {
        watcher.onPathsChange = { [weak self] _, _ in self?.scheduleRefresh() }
        watcher.start(path: transcriptsDirectory.path)
    }

    private func scheduleRefresh() {
        guard isVisible, refreshScheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshScheduled = nil
            if self.isVisible { self.rescan() }
        }
        refreshScheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func track(sessionID: String, owner: UUID) {
        guard trackedSessions[owner] != sessionID else { return }
        trackedSessions[owner] = sessionID
        start()
        if isVisible { rescan() }
    }

    func untrack(owner: UUID) {
        trackedSessions.removeValue(forKey: owner)
        stopIfUnused()
    }

    func loadNextPage() {
        guard hasMore, !isLoading else { return }
        requestedCount += Self.pageSize
        rescan()
    }

    func rescan() {
        guard !isLoading else { rescanPending = true; return }
        isLoading = true
        let limit = requestedCount
        let tracked = Set(trackedSessions.values)
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.scanClaude(directory: self.transcriptsDirectory, limit: limit + 1,
                                         tracked: tracked, index: &self.titleIndex)
            let combined = result.rows
            let bytes = self.titleIndex.bytesRead
            DispatchQueue.main.async {
                let visible = Array(combined.prefix(limit))
                if self.conversations != visible { self.conversations = visible }
                if self.aiTitlesBySessionId != result.titles { self.aiTitlesBySessionId = result.titles }
                self.hasMore = result.hasMore || combined.count > limit
                self.metadataBytesRead = bytes
                self.isLoading = false
                if self.rescanPending {
                    self.rescanPending = false
                    self.rescan()
                }
            }
        }
    }

    static func scan(directory: URL) -> [QuickConversation] {
        var index = TranscriptTitleIndex()
        let result = scanClaude(directory: directory, limit: Int.max, tracked: [], index: &index)
        return result.rows
    }

    static func scanAITitles(directory: URL) -> [String: String] {
        var index = TranscriptTitleIndex()
        return scanClaude(directory: directory, limit: Int.max, tracked: [], index: &index).titles
    }

    static func scanClaude(
        directory: URL, limit: Int, tracked: Set<String>, index: inout TranscriptTitleIndex
    ) -> (rows: [QuickConversation], titles: [String: String], hasMore: Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let descriptors = files.compactMap { file -> (URL, String, Date)? in
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", UUID(uuidString: id) != nil,
                  let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (file, id, modified)
        }.sorted { $0.2 == $1.2 ? $0.1 < $1.1 : $0.2 > $1.2 }
        var rows: [QuickConversation] = []
        var titles: [String: String] = [:]
        var seenTitles = Set<String>()
        var retained = Set<String>()
        var hasMore = false
        for (url, id, modified) in descriptors {
            let neededForPage = rows.count < limit
            if !neededForPage { hasMore = true }
            guard neededForPage || tracked.contains(id) else { continue }
            retained.insert(url.path)
            guard let metadata = index.metadata(for: url) else { continue }
            if let title = metadata.aiTitle { titles[id] = title }
            guard neededForPage, let title = metadata.title else { continue }
            let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard seenTitles.insert(normalized).inserted else { continue }
            rows.append(QuickConversation(id: id, title: title, aiTitle: metadata.aiTitle,
                                          modifiedAt: modified, transcriptURL: url))
        }
        index.retain(paths: retained)
        return (rows, titles, hasMore)
    }
}
