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

    /// 있으면 attach, 없으면 해당 디렉토리에서 생성.
    ///
    /// 생성을 `-d`로 하고 마지막은 항상 attach인 이유: 두 창이 같은 워크스페이스를
    /// 동시에 열면 `exec tmux new-session`끼리 경쟁해 진 쪽이 "duplicate session"
    /// 고아 프로세스로 남는다 (2026-07-19 재부팅에서 실제 발생 — 이 고아 하나가
    /// continuum의 프로세스 카운트 가드를 계속 오판시켜 자동 저장이 죽어 있었다).
    /// create-then-attach는 양쪽 모두 무해하게 attach로 수렴한다.
    static func attachOrCreateScript(sessionName: String, workingDirectory: String) -> String {
        let name = sessionName.shQuoted
        let dir = workingDirectory.shQuoted
        return """
        tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -c \(dir)
        exec tmux attach-session -t \(name)
        """
    }

    // MARK: - 콜드 부트 (tmux 서버가 없는 상태에서의 첫 기동)

    /// 앱 기동 시 탭 하나가 맡는 역할.
    enum StartupRole: Equatable {
        case warmAttach     // 서버가 이미 떠 있음 — 즉시 attach/create
        case coldBirther    // 서버 없음, 첫 클라이언트 — 서버를 깨우는 역할
        case coldFollower   // 콜드 부트 창(window) 안의 나머지 — 조용히 대기 후 attach
    }

    /// 콜드 부트를 특별 취급하는 이유: tmux-continuum은 tmux.conf 로드 시점에
    /// 프로세스 테이블에서 "다른 tmux 프로세스"가 보이면 다중 서버 상황으로 판단해
    /// 자동 복원과 자동 저장을 조용히 포기한다. 앱이 재부팅 직후 로그인 복원으로
    /// 창 여러 개의 attach를 동시에 쏟아내면 정확히 이 가드에 걸린다 —
    /// 2026-07-19 재부팅에서 저장된 세션 49개의 복원이 스킵되고 앱이 만든 빈
    /// 세션들이 이름을 선점하는 사고가 났다. 그래서 서버가 없으면: 첫 탭만
    /// 임시 세션(__sm_boot)으로 서버를 깨우고, 모든 탭은 가드 평가와 resurrect
    /// 복원이 끝날 때까지 tmux 명령을 한 번도 실행하지 않고 기다린 뒤 attach한다.
    ///
    /// 순수 함수 — 상태는 `startupScript`가 관리한다.
    static func startupRole(socketExists: Bool, coldBootAt: Date?, now: Date = Date()) -> StartupRole {
        if let t = coldBootAt, now.timeIntervalSince(t) < coldBootWindowSeconds {
            return .coldFollower
        }
        return socketExists ? .warmAttach : .coldBirther
    }

    /// 콜드 부트 창: birther의 서버 기동 + conf 로드 + 가드 평가 + 복원 시작을
    /// 덮고도 남는 시간. 이 창이 지난 뒤의 탭은 평상시(warm) 경로로 돌아간다.
    static let coldBootWindowSeconds: TimeInterval = 15

    /// 탭이 실행할 부트스트랩 스크립트 선택. 메인 스레드에서만 호출된다
    /// (PTY 시작은 WKWebView ready 콜백 → 메인 스레드 경유).
    static func startupScript(sessionName: String, workingDirectory: String) -> String {
        let role = startupRole(socketExists: serverSocketExists, coldBootAt: coldBootAt)
        switch role {
        case .warmAttach:
            return attachOrCreateScript(sessionName: sessionName, workingDirectory: workingDirectory)
        case .coldBirther:
            coldBootAt = Date()
            return coldBootScript(sessionName: sessionName, workingDirectory: workingDirectory, birther: true)
        case .coldFollower:
            return coldBootScript(sessionName: sessionName, workingDirectory: workingDirectory, birther: false)
        }
    }

    private static var coldBootAt: Date?

    /// tmux 기본 소켓 존재 여부 (서버 생존의 근사치 — 즉시 반환, 프로세스 스폰 없음)
    static var serverSocketExists: Bool {
        let tmpDir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
        return FileManager.default.fileExists(atPath: "\(tmpDir)/tmux-\(getuid())/default")
    }

    /// 콜드 부트 스크립트. birther는 임시 세션으로 서버를 깨운 뒤 정리까지 맡는다.
    ///
    /// 시퀀스: (birther만) __sm_boot 생성으로 서버 기동 → 전원 4초 침묵
    /// (continuum 가드가 프로세스 테이블을 검사하는 창 — 이 동안 tmux 명령 금지)
    /// → 목표 세션이 나타날 때까지 폴링 (resurrect 복원이 채워주는 시간; 복원
    /// 프로세스가 이미 사라졌으면 일찍 탈출) → 없으면 생성 → attach.
    static func coldBootScript(sessionName: String, workingDirectory: String, birther: Bool) -> String {
        let name = sessionName.shQuoted
        let dir = workingDirectory.shQuoted
        let birthLine = birther ? "tmux new-session -d -s __sm_boot -c \(dir) 2>/dev/null\n" : ""
        let cleanupLine = birther ? "tmux kill-session -t __sm_boot 2>/dev/null\n" : ""
        return """
        \(birthLine)sleep 4
        i=0
        until tmux has-session -t \(name) 2>/dev/null; do
          i=$((i+1))
          [ "$i" -ge 32 ] && break
          if [ "$i" -ge 8 ] && ! pgrep -qf 'tmux-resurrect/scripts/restore.sh'; then break; fi
          sleep 0.25
        done
        tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -c \(dir)
        \(cleanupLine)exec tmux attach-session -t \(name)
        """
    }

    /// tmux 바이너리 경로. 첫 접근 시 1회 평가 후 캐시.
    ///
    /// 파일 시스템 검사만 사용한다 — 이전 구현(로그인 셸 스폰 + waitUntilExit)은
    /// 메인 스레드에서 첫 평가될 때 waitUntilExit이 런루프를 재진입 펌핑해
    /// SwiftUI가 같은 static let을 다시 터치 → dispatch_once 재귀 → 크래시했다.
    /// 파일 검사는 즉시 반환이라 그 문제 클래스 자체가 없다.
    static let tmuxPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Apple Silicon homebrew
            "/usr/local/bin/tmux",      // Intel homebrew
            "/usr/bin/tmux",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // PATH 폴백 (GUI 앱의 PATH는 제한적이지만 위 후보가 대부분을 커버)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { "\($0)/tmux" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isTmuxAvailable: Bool { tmuxPath != nil }

    /// 콜드부트 가드 창 안인지 — 이 동안엔 부트스트랩 외의 어떤 tmux 명령도 삼가야 한다.
    /// (폴링·테마 동기화 등이 이 창에 tmux 프로세스를 띄우면 continuum 가드가
    /// 다중 서버로 오판해 세션 복원·자동 저장을 포기한다. 2026-07-19 사고의 원인.)
    static var isInColdBootWindow: Bool {
        guard let t = coldBootAt else { return false }
        return Date().timeIntervalSince(t) < coldBootWindowSeconds
    }
}

extension String {
    /// POSIX 셸 단일 인용 이스케이프
    var shQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
