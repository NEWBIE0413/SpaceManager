import Foundation

/// tmux 세션명 규칙과 attach/create 부트스트랩.
/// 세션의 저장·복원은 유저의 tmux-resurrect/continuum이 담당하고, 앱은 이름으로 attach만 한다.
enum TmuxBootstrap {
    /// tmux가 금지하는 `.` `:` 및 공백을 `-`로 치환. 빈 결과는 "workspace" 폴백.
    static func sanitizeSessionName(_ raw: String) -> String {
        let mapped = raw.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
            (ch == "." || ch == ":" || ch == " ") ? "-" : ch
        }
        let result = String(mapped)
        return result.isEmpty ? "workspace" : result
    }

    /// 있으면 attach, 없으면 해당 디렉토리에서 생성. (`tmux new -A`와 동등, 기존 검증 로직 계승)
    static func attachOrCreateScript(sessionName: String, workingDirectory: String) -> String {
        let name = sessionName.shQuoted
        let dir = workingDirectory.shQuoted
        return """
        if tmux has-session -t \(name) 2>/dev/null; then
          exec tmux attach-session -t \(name)
        else
          exec tmux new-session -s \(name) -c \(dir)
        fi
        """
    }

    /// 로그인 셸 PATH 기준 tmux 존재 여부 (homebrew 경로 포함). 첫 접근 시 1회 평가 후 캐시.
    static let isTmuxAvailable: Bool = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v tmux >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()
}

extension String {
    /// POSIX 셸 단일 인용 이스케이프
    var shQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
