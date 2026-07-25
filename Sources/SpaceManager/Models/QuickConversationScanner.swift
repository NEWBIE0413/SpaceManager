import Foundation

struct QuickConversation: Identifiable, Equatable {
    let id: String          // transcript 파일명의 UUID = ccv -ry 인자
    let title: String
    let modifiedAt: Date
    let transcriptURL: URL
}

/// ~/cld 전용 Claude transcript 목록. 변경된 파일만 다시 파싱하고 제목이 같은
/// resume 파생 파일은 최신 하나로 접어 Claude Desktop식 최근 목록을 만든다.
final class QuickConversationScanner: ObservableObject {
    static let shared = QuickConversationScanner()
    static let refreshInterval: TimeInterval = 5

    @Published private(set) var conversations: [QuickConversation] = []

    private struct CacheEntry {
        let modifiedAt: Date
        let conversation: QuickConversation?
    }

    private let transcriptsDirectory: URL
    private let queue = DispatchQueue(label: "SpaceManager.QuickConversations", qos: .utility)
    private var cache: [String: CacheEntry] = [:]
    private var timer: Timer?

    init(transcriptsDirectory: URL = Self.defaultTranscriptsDirectory()) {
        self.transcriptsDirectory = transcriptsDirectory
    }

    private static func defaultTranscriptsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let quickDirectory = home.appendingPathComponent("cld", isDirectory: true)
        let encodedProjectPath = quickDirectory.path.replacingOccurrences(of: "/", with: "-")
        return home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encodedProjectPath, isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func rescan() {
        let directory = transcriptsDirectory
        queue.async { [weak self] in
            guard let self else { return }
            let scanned = Self.scan(directory: directory, cache: &self.cache)
            DispatchQueue.main.async {
                if self.conversations != scanned {
                    self.conversations = scanned
                }
            }
        }
    }

    static func scan(directory: URL) -> [QuickConversation] {
        var cache: [String: CacheEntry] = [:]
        return scan(directory: directory, cache: &cache)
    }

    private static func scan(
        directory: URL,
        cache: inout [String: CacheEntry]
    ) -> [QuickConversation] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            cache.removeAll()
            return []
        }

        var found: [QuickConversation] = []
        var livePaths = Set<String>()
        for file in files where file.pathExtension == "jsonl" {
            let sessionId = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: sessionId) != nil,
                  let modifiedAt = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                  ))?.contentModificationDate else { continue }

            livePaths.insert(file.path)
            if let cached = cache[file.path], cached.modifiedAt == modifiedAt {
                if let conversation = cached.conversation { found.append(conversation) }
                continue
            }

            let parsed = parseTranscript(file, sessionId: sessionId, modifiedAt: modifiedAt)
            cache[file.path] = CacheEntry(modifiedAt: modifiedAt, conversation: parsed)
            if let parsed { found.append(parsed) }
        }
        cache = cache.filter { livePaths.contains($0.key) }

        // Claude resume가 새 sessionId 파일을 만들면 ai-title이 같은 transcript가
        // 복수 생길 수 있다. 같은 표시 제목은 최신 파일을 resume 대상으로 삼는다.
        var newestByTitle: [String: QuickConversation] = [:]
        for conversation in found {
            let key = normalizedTitle(conversation.title)
            if let existing = newestByTitle[key], existing.modifiedAt >= conversation.modifiedAt {
                continue
            }
            newestByTitle[key] = conversation
        }
        return newestByTitle.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func parseTranscript(
        _ url: URL,
        sessionId: String,
        modifiedAt: Date
    ) -> QuickConversation? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lastAITitle: String?
        var firstUserTitle: String?
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any] else { continue }
            if object["type"] as? String == "ai-title",
               let title = object["aiTitle"] as? String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lastAITitle = trimmed }
            } else if firstUserTitle == nil,
                      let userText = RecentActivityScanner.userText(from: object) {
                firstUserTitle = userText
            }
        }
        guard let title = lastAITitle ?? firstUserTitle else { return nil }
        return QuickConversation(
            id: sessionId,
            title: title,
            modifiedAt: modifiedAt,
            transcriptURL: url
        )
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
