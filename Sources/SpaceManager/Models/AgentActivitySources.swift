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
}

enum AgentActivitySources {
    static func scanCodex(sessionsDir: URL, now: Date = Date()) -> [AgentActivityRecord] {
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
                  let record = parseCodex(file: file),
                  record.lastActivity > cutoff else { continue }
            result.append(record)
        }
        return result
    }

    static func scanGemini(geminiDir: URL, now: Date = Date()) -> [AgentActivityRecord] {
        var records = scanAntigravity(geminiDir: geminiDir, now: now)
        records.append(contentsOf: scanClassicGemini(geminiDir: geminiDir, now: now))
        return records
    }

    private static func parseCodex(file: URL) -> AgentActivityRecord? {
        guard let head = readPrefix(file, maxBytes: 65_536),
              let tail = readTail(file, maxBytes: 131_072) else { return nil }

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
                activity = parseTimestamp(raw)
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

    private static func scanAntigravity(geminiDir: URL, now: Date) -> [AgentActivityRecord] {
        let root = geminiDir.appendingPathComponent("antigravity-cli")
        let history = root.appendingPathComponent("history.jsonl")
        guard let text = readTail(history, maxBytes: 1_048_576) else { return [] }
        let cutoff = now.addingTimeInterval(-RecentActivityScanner.dotWindow)
        var latest: [String: (cwd: String, date: Date, snippet: String?)] = [:]
        for object in jsonObjects(in: text) {
            guard let id = object["conversationId"] as? String,
                  let cwd = object["workspace"] as? String,
                  let millis = object["timestamp"] as? NSNumber else { continue }
            let date = Date(timeIntervalSince1970: millis.doubleValue / 1000)
            guard date > cutoff else { continue }
            let snippet = (object["display"] as? String).map(cleanSnippet)
            if latest[id]?.date ?? .distantPast < date { latest[id] = (cwd, date, snippet) }
        }

        return latest.map { id, entry in
            let transcript = root
                .appendingPathComponent("brain/\(id)/.system_generated/logs/transcript.jsonl")
            let transcriptDate = lastGeminiTranscriptDate(transcript) ?? entry.date
            return AgentActivityRecord(
                id: "gemini:\(id)", provider: .gemini, cwd: entry.cwd,
                lastActivity: max(entry.date, transcriptDate), snippet: entry.snippet,
                growingFile: FileManager.default.fileExists(atPath: transcript.path) ? transcript : nil
            )
        }
    }

    private static func scanClassicGemini(geminiDir: URL, now: Date) -> [AgentActivityRecord] {
        let projectsFile = geminiDir.appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: projectsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: String] else { return [] }
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
                      let record = parseClassicGemini(file: file, cwd: cwd, fallback: mtime),
                      record.lastActivity > cutoff else { continue }
                result.append(record)
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
            if let raw = object["lastUpdated"] as? String, let parsed = parseTimestamp(raw) { activity = parsed }
            if let messages = object["messages"] as? [[String: Any]] {
                snippet = messages.reversed().compactMap(geminiUserText).first
            }
        } else if let text = String(data: data, encoding: .utf8) {
            for object in jsonObjects(in: text).reversed() {
                if let raw = (object["timestamp"] ?? (object["$set"] as? [String: Any])?["lastUpdated"]) as? String,
                   let parsed = parseTimestamp(raw), parsed > activity { activity = parsed }
                if snippet == nil { snippet = geminiUserText(object) }
            }
        }
        return AgentActivityRecord(
            id: "gemini:\(id)", provider: .gemini, cwd: cwd,
            lastActivity: activity, snippet: snippet, growingFile: file
        )
    }

    private static func lastGeminiTranscriptDate(_ file: URL) -> Date? {
        guard let text = readTail(file, maxBytes: 131_072) else { return nil }
        for object in jsonObjects(in: text).reversed() {
            if let raw = object["created_at"] as? String, let date = parseTimestamp(raw) { return date }
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

    private static func jsonObjects(in text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func readPrefix(_ file: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readTail(_ file: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size - min(size, maxBytes))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
