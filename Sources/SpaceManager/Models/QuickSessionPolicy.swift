import Foundation

enum QuickLaunch: Equatable {
    case blank
    case initialPrompt(String)
    case resume(sessionId: String)
}

/// 헤르메스 창의 일상 대화 탭 규칙. 탭은 tmux와 무관한 일회성 PTY다.
enum QuickSessionPolicy {
    static let initialSessionName = "새 대화 세션"

    /// `ccv`는 Claude Code에 짧은 플래그를 붙여주는 개인용 런처다. 있으면 그것을 쓰고,
    /// 없으면 `claude`를 직접 부른다 — 이 저장소를 받은 사람에게 ccv가 있을 이유가 없다.
    static var ccvExecutablePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("myworld/ccv", isDirectory: false).path,
            home.appendingPathComponent(".local/bin/claude", isDirectory: false).path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// 어떤 런처를 잡았는지. 플래그 모양이 다르므로 명령을 만들 때 알아야 한다.
    static var usesCcvWrapper: Bool {
        URL(fileURLWithPath: ccvExecutablePath).lastPathComponent == "ccv"
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
        configuration: QuickSessionConfiguration = .default,
        usesWrapper: Bool = usesCcvWrapper
    ) -> String {
        // ccv는 -y/-ry로 줄여 받고, claude 본체는 긴 플래그를 받는다.
        // --model과 --effort는 양쪽이 같으므로 그대로 둔다.
        let skip = usesWrapper ? "-y" : "--dangerously-skip-permissions"
        let model = #"--model "$SM_MODEL" --effort "$SM_EFFORT""#
        switch launch {
        case .blank:
            return #"exec "$SM_CCV" \#(skip) \#(model)"#
        case .initialPrompt:
            return #"exec "$SM_CCV" \#(skip) \#(model) "$SM_INITIAL_PROMPT""#
        case .resume:
            let resume = usesWrapper
                ? #"-ry "$SM_RESUME_SESSION_ID""#
                : #"--resume "$SM_RESUME_SESSION_ID" \#(skip)"#
            return #"exec "$SM_CCV" \#(resume) \#(model)"#
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
