import Foundation

enum AgentProvider: String, Equatable {
    case claude
    case codex
    case gemini
}

struct AgentActivityRecord: Equatable {
    let id: String
    let provider: AgentProvider
    let cwd: String
    let lastActivity: Date
    let snippet: String?
    let growingFile: URL?
    /// 원격 미러에서 온 레코드면 ssh 별칭. 로컬은 nil.
    var host: String? = nil
}

enum AgentActivitySources {
    struct HistoryEntry {
        let cwd: String
        let date: Date
        let snippet: String?
    }

    struct Cache {
        var codex = FileMetadataCache<AgentActivityRecord>()
        var history = FileMetadataCache<[String: HistoryEntry]>()
        var transcriptDates = FileMetadataCache<Date>()
        var projects = FileMetadataCache<[String: String]>()
        var classic = FileMetadataCache<AgentActivityRecord>()
        var loadCount: Int {
            codex.loadCount + history.loadCount + transcriptDates.loadCount + projects.loadCount + classic.loadCount
        }
    }

    static func scanCodex(sessionsDir: URL, now: Date = Date()) -> [AgentActivityRecord] {
        var cache = Cache()
        return scanCodex(sessionsDir: sessionsDir, cache: &cache, now: now)
    }

    static func scanCodex(sessionsDir: URL, cache: inout Cache, now: Date = Date()) -> [AgentActivityRecord] {
        cache.codex.beginPass()
        defer { cache.codex.endPass() }
        let cutoff = now.addingTimeInterval(-RecentActivityScanner.dotWindow)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [AgentActivityRecord] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  mtime > cutoff,
                  let record = cache.codex.value(for: file, load: { parseCodex(file: file) }),
                  record.lastActivity > cutoff else { continue }
            result.append(record)
        }
        return result
    }

    static func scanGemini(geminiDir: URL, now: Date = Date()) -> [AgentActivityRecord] {
        var cache = Cache()
        return scanGemini(geminiDir: geminiDir, cache: &cache, now: now)
    }

    static func scanGemini(geminiDir: URL, cache: inout Cache, now: Date = Date()) -> [AgentActivityRecord] {
        cache.history.beginPass()
        cache.transcriptDates.beginPass()
        cache.projects.beginPass()
        cache.classic.beginPass()
        defer {
            cache.history.endPass()
            cache.transcriptDates.endPass()
            cache.projects.endPass()
            cache.classic.endPass()
        }
        return scanAntigravity(geminiDir: geminiDir, cache: &cache, now: now)
            + scanClassicGemini(geminiDir: geminiDir, cache: &cache, now: now)
    }

    private static func parseCodex(file: URL) -> AgentActivityRecord? {
        guard let head = readPrefix(file, maxBytes: 65_536),
              let tail = TranscriptJSON.tail(file) else { return nil }

        var cwd: String?
        var sessionID = file.deletingPathExtension().lastPathComponent
        for object in jsonObjects(in: head) where object["type"] as? String == "session_meta" {
            guard let payload = object["payload"] as? [String: Any] else { continue }
            cwd = payload["cwd"] as? String
            sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID
            break
        }
        guard let cwd else { return nil }

        var activity: Date?
        var snippet: String?
        for object in jsonObjects(in: tail).reversed() {
            if activity == nil, let raw = object["timestamp"] as? String {
                activity = TranscriptJSON.timestamp(raw)
            }
            if snippet == nil { snippet = codexUserText(object) }
            if activity != nil && snippet != nil { break }
        }
        guard let activity else { return nil }
        return AgentActivityRecord(
            id: "codex:\(sessionID)", provider: .codex, cwd: cwd,
            lastActivity: activity, snippet: snippet, growingFile: file
        )
    }

    private static func scanAntigravity(geminiDir: URL, cache: inout Cache, now: Date) -> [AgentActivityRecord] {
        let root = geminiDir.appendingPathComponent("antigravity-cli")
        let history = root.appendingPathComponent("history.jsonl")
        guard let latest = cache.history.value(for: history, load: {
            guard let data = TranscriptJSON.tail(history, maxBytes: 1_048_576) else { return nil }
            var latest: [String: HistoryEntry] = [:]
            for object in jsonObjects(in: data) {
                guard let id = object["conversationId"] as? String,
                      let cwd = object["workspace"] as? String,
                      let millis = object["timestamp"] as? NSNumber else { continue }
                let date = Date(timeIntervalSince1970: millis.doubleValue / 1000)
                if latest[id]?.date ?? .distantPast < date {
                    latest[id] = HistoryEntry(cwd: cwd, date: date,
                        snippet: (object["display"] as? String).map(cleanSnippet))
                }
            }
            return latest
        }) else { return [] }
        let cutoff = now.addingTimeInterval(-RecentActivityScanner.dotWindow)
        return latest.filter { $0.value.date > cutoff }.map { id, entry in
            let transcript = root.appendingPathComponent("brain/\(id)/.system_generated/logs/transcript.jsonl")
            let transcriptDate = cache.transcriptDates.value(for: transcript) { lastGeminiTranscriptDate(transcript) }
            return AgentActivityRecord(
                id: "gemini:\(id)", provider: .gemini, cwd: entry.cwd,
                lastActivity: max(entry.date, transcriptDate ?? entry.date), snippet: entry.snippet,
                growingFile: FileManager.default.fileExists(atPath: transcript.path) ? transcript : nil
            )
        }
    }

    private static func scanClassicGemini(geminiDir: URL, cache: inout Cache, now: Date) -> [AgentActivityRecord] {
        let projectsFile = geminiDir.appendingPathComponent("projects.json")
        guard let projects = cache.projects.value(for: projectsFile, load: {
            guard let data = try? Data(contentsOf: projectsFile),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return root["projects"] as? [String: String]
        }) else { return [] }
        let cutoff = now.addingTimeInterval(-RecentActivityScanner.dotWindow)
        var result: [AgentActivityRecord] = []
        for (cwd, projectKey) in projects {
            let chats = geminiDir.appendingPathComponent("tmp/\(projectKey)/chats")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("session-") {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff,
                      let record = cache.classic.value(for: file, load: { parseClassicGemini(file: file, cwd: cwd, fallback: mtime) }),
                      record.lastActivity > cutoff else { continue }
                result.append(AgentActivityRecord(id: record.id, provider: .gemini, cwd: cwd,
                    lastActivity: record.lastActivity, snippet: record.snippet, growingFile: file))
            }
        }
        return result
    }

    private static func parseClassicGemini(file: URL, cwd: String, fallback: Date) -> AgentActivityRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        var id = file.deletingPathExtension().lastPathComponent
        var activity = fallback
        var snippet: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            id = object["sessionId"] as? String ?? id
            if let raw = object["lastUpdated"] as? String, let parsed = TranscriptJSON.timestamp(raw) { activity = parsed }
            if let messages = object["messages"] as? [[String: Any]] {
                snippet = messages.reversed().compactMap(geminiUserText).first
            }
        } else {
            for object in jsonObjects(in: data).reversed() {
                if let raw = (object["timestamp"] ?? (object["$set"] as? [String: Any])?["lastUpdated"]) as? String,
                   let parsed = TranscriptJSON.timestamp(raw), parsed > activity { activity = parsed }
                if snippet == nil { snippet = geminiUserText(object) }
            }
        }
        return AgentActivityRecord(
            id: "gemini:\(id)", provider: .gemini, cwd: cwd,
            lastActivity: activity, snippet: snippet, growingFile: file
        )
    }

    private static func lastGeminiTranscriptDate(_ file: URL) -> Date? {
        guard let text = TranscriptJSON.tail(file) else { return nil }
        for object in jsonObjects(in: text).reversed() {
            if let raw = object["created_at"] as? String, let date = TranscriptJSON.timestamp(raw) { return date }
        }
        return nil
    }

    private static func codexUserText(_ object: [String: Any]) -> String? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        if payload["type"] as? String == "user_message", let message = payload["message"] as? String {
            return cleanSnippet(message)
        }
        guard payload["type"] as? String == "message", payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.first.map(cleanSnippet)
    }

    private static func geminiUserText(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "user", let content = object["content"] as? String else { return nil }
        return cleanSnippet(content)
    }

    private static func cleanSnippet(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ").prefix(240))
    }

    private static func jsonObjects(in data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { TranscriptJSON.object(Data($0)) }
    }

    private static func readPrefix(_ file: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}
