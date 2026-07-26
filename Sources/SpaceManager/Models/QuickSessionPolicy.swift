import Foundation

enum QuickLaunch: Equatable {
    case blank
    case initialPrompt(String)
    case resume(sessionId: String)
}

/// 헤르메스 창의 일상 대화 탭 규칙. 탭은 tmux와 무관한 일회성 PTY다.
enum QuickSessionPolicy {
    static let initialSessionName = "새 대화 세션"

    static var ccvExecutablePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("myworld/ccv", isDirectory: false)
            .path
    }

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

    static func launchCommand(
        for launch: QuickLaunch,
        configuration: QuickSessionConfiguration = .default
    ) -> String {
        switch launch {
        case .blank:
            return #"exec "$SM_CCV" -y --model "$SM_MODEL" --effort "$SM_EFFORT""#
        case .initialPrompt:
            return #"exec "$SM_CCV" -y --model "$SM_MODEL" --effort "$SM_EFFORT" "$SM_INITIAL_PROMPT""#
        case .resume:
            return #"exec "$SM_CCV" -ry "$SM_RESUME_SESSION_ID" --model "$SM_MODEL" --effort "$SM_EFFORT""#
        }
    }

    static func environment(
        for launch: QuickLaunch,
        configuration: QuickSessionConfiguration = .default
    ) -> [String: String] {
        var environment = [
            "SM_CCV": ccvExecutablePath.replacingOccurrences(of: "\0", with: ""),
            "SM_MODEL": configuration.modelID.replacingOccurrences(of: "\0", with: ""),
            "SM_EFFORT": configuration.effort.rawValue,
        ]
        switch launch {
        case .blank:
            break
        case .initialPrompt(let prompt):
            environment["SM_INITIAL_PROMPT"] = prompt.replacingOccurrences(of: "\0", with: "")
        case .resume(let sessionId):
            environment["SM_RESUME_SESSION_ID"] = sessionId
        }
        if configuration.usesProxy {
            environment["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4141"
            environment["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
        }
        return environment
    }

    static func applyingEnvironment(
        _ base: [String: String],
        launch: QuickLaunch,
        configuration: QuickSessionConfiguration
    ) -> [String: String] {
        var result = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let requiredPaths = [home + "/.local/bin", "/opt/homebrew/bin"]
        let inheritedPaths = (result["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        result["PATH"] = (requiredPaths + inheritedPaths).reduce(into: [String]()) { paths, path in
            guard !path.isEmpty, !paths.contains(path) else { return }
            paths.append(path)
        }.joined(separator: ":")
        // A direct Claude session must stay direct even if SpaceManager itself
        // was launched from a shell that happened to have gateway variables.
        result.removeValue(forKey: "ANTHROPIC_BASE_URL")
        result.removeValue(forKey: "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY")
        for (key, value) in environment(for: launch, configuration: configuration) {
            result[key] = value
        }
        return result
    }

}
