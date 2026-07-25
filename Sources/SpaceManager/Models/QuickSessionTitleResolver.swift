import Foundation

/// 실행 중인 Claude의 ephemeral session registry를 Quick transcript UUID로 연결한다.
/// registry의 derived `name`은 의도적으로 디코딩하지 않는다 — 탭 표시명은 오직
/// transcript의 ai-title만 사용한다.
enum QuickSessionTitleResolver {
    private struct ClaudeSessionRecord: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
    }

    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    static func sessionId(
        processIdentifier: pid_t,
        sessionsDirectory: URL = QuickSessionTitleResolver.sessionsDirectory,
        expectedWorkingDirectory: String = QuickSessionPolicy.workingDirectory
    ) -> String? {
        let recordURL = sessionsDirectory
            .appendingPathComponent("\(processIdentifier)")
            .appendingPathExtension("json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data),
              record.pid == processIdentifier,
              UUID(uuidString: record.sessionId) != nil,
              standardized(record.cwd) == standardized(expectedWorkingDirectory) else {
            return nil
        }
        return record.sessionId
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
