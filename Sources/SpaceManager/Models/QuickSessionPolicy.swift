import Foundation

enum QuickLaunch: Equatable {
    case blank
    case initialPrompt(String)
    case resume(sessionId: String)
}

/// 헤르메스 창의 일상 대화 탭 규칙. q-N은 창 안의 표시명일 뿐 tmux 세션명이 아니다.
enum QuickSessionPolicy {
    static var workingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("cld", isDirectory: true)
            .path
    }

    @discardableResult
    static func ensureWorkingDirectory(
        fileManager: FileManager = .default
    ) -> String {
        let path = workingDirectory
        try? fileManager.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        return path
    }

    static func launchCommand(for launch: QuickLaunch) -> String {
        switch launch {
        case .blank:
            return "exec ccv -y"
        case .initialPrompt:
            return #"exec ccv -y "$SM_INITIAL_PROMPT""#
        case .resume:
            return #"exec ccv -ry "$SM_RESUME_SESSION_ID""#
        }
    }

    static func environment(for launch: QuickLaunch) -> [String: String] {
        switch launch {
        case .blank:
            return [:]
        case .initialPrompt(let prompt):
            return ["SM_INITIAL_PROMPT": prompt.replacingOccurrences(of: "\0", with: "")]
        case .resume(let sessionId):
            return ["SM_RESUME_SESSION_ID": sessionId]
        }
    }

    static func nextName(usedNames: Set<String>) -> String {
        var number = 1
        while usedNames.contains("q-\(number)") {
            number += 1
        }
        return "q-\(number)"
    }
}
