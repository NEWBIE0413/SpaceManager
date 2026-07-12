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

    /// tmux 존재 여부. 첫 접근 시 1회 평가 후 캐시.
    ///
    /// 파일 시스템 검사만 사용한다 — 이전 구현(로그인 셸 스폰 + waitUntilExit)은
    /// 메인 스레드에서 첫 평가될 때 waitUntilExit이 런루프를 재진입 펌핑해
    /// SwiftUI가 같은 static let을 다시 터치 → dispatch_once 재귀 → 크래시했다.
    /// 파일 검사는 즉시 반환이라 그 문제 클래스 자체가 없다.
    static let isTmuxAvailable: Bool = {
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Apple Silicon homebrew
            "/usr/local/bin/tmux",      // Intel homebrew
            "/usr/bin/tmux",
        ]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        // PATH 폴백 (GUI 앱의 PATH는 제한적이지만 위 후보가 대부분을 커버)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/tmux")
        }
    }()
}

extension String {
    /// POSIX 셸 단일 인용 이스케이프
    var shQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
