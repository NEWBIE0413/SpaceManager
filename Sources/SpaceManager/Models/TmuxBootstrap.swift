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

    /// 콜드 부트 창: 외부 복구 파이프라인(continuum 레이아웃 복원 + 세션복구
    /// 에이전트의 에이전트 재주입)이 끝나기까지 걸릴 수 있는 시간을 덮는다.
    /// 이 창 안에 시작하는 모든 탭은 "선점하지 않는" 인내 스크립트를 쓴다 —
    /// 창이 짧으면 유저가 부팅 직후 연 탭이 warm 경로로 새 세션을 만들어
    /// 복원될 이름을 가로챈다 (2026-07-24 사고의 한 갈래).
    static let coldBootWindowSeconds: TimeInterval = 150

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

    /// 콜드 부트 스크립트 v2 — 앱은 부팅 복구의 "순수 follower"다.
    ///
    /// 이 머신의 재부팅 복구는 앱 밖의 파이프라인이 담당한다: continuum이 레이아웃
    /// (세션/창/패널)을 복원하고, 세션복구 에이전트가 각 패널에 에이전트를 재주입한다.
    /// 앱이 그보다 먼저 세션을 만들면 resurrect가 그 이름을 건너뛰어 레이아웃이
    /// 유실되고 에이전트 주입 좌표가 어긋난다 (2026-07-24 사고). 그래서:
    ///
    /// 1) 댕글링 `last` 자가치유 — 재부팅 직전 저장이 디스크에 못 남으면 심링크가
    ///    허공을 가리켜 복원 전체가 즉사한다. 최신 실존 저장본으로 교정.
    /// 2) 서버 대기를 tmux 명령 없이 소켓 파일 폴링으로 — 폴링 프로세스가
    ///    conf 로드 시점에 잡히면 continuum 가드가 다중 서버로 오판한다.
    ///    저장본이 있으면 60초까지 기다린다 (부팅 폭주에서 파이프라인은 느리다).
    /// 3) birther는 그 뒤에도 서버가 없을 때만 깨운다 (파이프라인 부재 폴백).
    ///    미데몬화 서버를 문 채 행할 수 있으므로 15초 watchdog으로 반드시 끝낸다.
    /// 4) 저장본에 이 세션명이 있으면 60초까지 생성하지 않는다 — 복원이 채울
    ///    이름을 앱이 가로채는 게 사고의 본질이었다. 없으면 신규이니 짧게 대기 후 생성.
    static func coldBootScript(sessionName: String, workingDirectory: String, birther: Bool) -> String {
        coldBootScript(sessionName: sessionName, directoryExpression: workingDirectory.shQuoted, birther: birther)
    }

    /// `directoryExpression`은 이미 셸-안전한 표현식이다 (예: `'/tmp/x'` 또는 `"$HOME/"'proj'`).
    static func coldBootScript(sessionName: String, directoryExpression: String, birther: Bool) -> String {
        let name = sessionName.shQuoted
        let dir = directoryExpression
        let birthBlock = birther ? """
        if [ ! -S "$SOCK" ]; then
          tmux new-session -d -s __sm_boot -c \(dir) 2>/dev/null &
          BIRTH_PID=$!
          (
            sleep 15
            if [ ! -S "$SOCK" ]; then
              kill -TERM "$BIRTH_PID" 2>/dev/null
              sleep 2
              [ -S "$SOCK" ] || kill -KILL "$BIRTH_PID" 2>/dev/null
            fi
          ) &
          BIRTH_GUARD=$!
          j=0; while [ ! -S "$SOCK" ] && [ $j -lt 60 ]; do sleep 0.5; j=$((j+1)); done
          if [ -S "$SOCK" ]; then
            kill "$BIRTH_GUARD" 2>/dev/null
            wait "$BIRTH_GUARD" 2>/dev/null
            disown "$BIRTH_PID" 2>/dev/null || true
          else
            wait "$BIRTH_PID" 2>/dev/null
            wait "$BIRTH_GUARD" 2>/dev/null
          fi
        fi
        """ : """
        j=0; while [ ! -S "$SOCK" ] && [ $j -lt 70 ]; do sleep 0.5; j=$((j+1)); done
        """
        let cleanupLine = birther ? "tmux kill-session -t __sm_boot 2>/dev/null\n" : ""
        return """
        RES="$HOME/.local/share/tmux/resurrect"
        if [ -L "$RES/last" ] && [ ! -e "$RES/last" ]; then
          newest=$(ls -t "$RES"/tmux_resurrect_*.txt 2>/dev/null | head -1)
          [ -n "$newest" ] && ln -sf "$(basename "$newest")" "$RES/last"
        fi
        SOCK="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
        PATIENCE=120; [ -e "$RES/last" ] || PATIENCE=20
        i=0
        while [ ! -S "$SOCK" ] && [ $i -lt $PATIENCE ]; do sleep 0.5; i=$((i+1)); done
        \(birthBlock)
        sleep 5
        WAIT=20
        if [ -e "$RES/last" ] && awk -F'\\t' -v n=\(name) '$1=="pane" && $2==n {f=1} END {exit !f}' "$RES/last" 2>/dev/null; then
          WAIT=120
        fi
        i=0
        until tmux has-session -t \(name) 2>/dev/null; do
          i=$((i+1))
          [ "$i" -ge "$WAIT" ] && break
          sleep 0.5
        done
        tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -c \(dir)
        \(cleanupLine)exec tmux attach-session -t \(name)
        """
    }

    // MARK: - 원격 호스트 (tmux 서버가 다른 머신에 있을 때)

    /// 원격 작업 디렉토리. 로컬 홈 아래 경로는 원격 `$HOME` 기준으로 옮긴다 — 두 머신의
    /// 홈 경로가 다르므로(/Users vs /home) 절대경로를 그대로 보내면 없는 디렉토리가 된다.
    enum RemoteDirectory: Equatable {
        case relativeToHome(String)
        case absolute(String)

        /// 원격 셸이 해석할 표현식. 홈 상대경로는 `"$HOME/"'rel'`로 만들어 `$HOME`만 확장되고
        /// 나머지는 인용된 채 남는다.
        var shellExpression: String {
            switch self {
            case .relativeToHome(let rel): return "\"$HOME/\"" + rel.shQuoted
            case .absolute(let abs): return abs.shQuoted
            }
        }
    }

    static func remoteDirectory(forLocalPath path: String, localHome: String = NSHomeDirectory()) -> RemoteDirectory {
        let home = localHome.hasSuffix("/") ? String(localHome.dropLast()) : localHome
        if path == home { return .relativeToHome("") }
        if path.hasPrefix(home + "/") {
            return .relativeToHome(String(path.dropFirst(home.count + 1)))
        }
        return .absolute(path)
    }

    /// 원격에서 실행될 부트스트랩. 원격 서버의 소켓 유무는 여기서 알 수 없으므로 판단을
    /// 스크립트 안으로 옮긴다: 서버가 있으면 즉시 attach/create, 없으면 로컬과 같은
    /// 콜드 부트 인내 스크립트(continuum 복원을 가로채지 않기)로 내려간다.
    static func remoteStartupScript(sessionName: String, remoteDirectory: RemoteDirectory) -> String {
        let name = sessionName.shQuoted
        let dir = remoteDirectory.shellExpression
        let cold = coldBootScript(sessionName: sessionName, directoryExpression: "\"$WD\"", birther: true)
        return """
        WD=\(dir)
        # The managed server can expose its socket before ExecStartPost restores
        # the saved panes. systemd start waits for that job instead of creating
        # an empty session that would claim the saved session's name.
        if [ -f "$HOME/.config/systemd/user/tmux-server.service.d/persistence.conf" ]; then
          systemctl --user start tmux-server.service || exit 1
        fi
        SOCK="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
        if [ -S "$SOCK" ]; then
          tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -c "$WD"
          exec tmux attach-session -t \(name)
        fi
        \(cold)
        """
    }

    /// 로컬 셸이 실행할 한 줄: `ssh -t host 'bash -lc <script>'`. `-t`로 원격에 pty를 주어
    /// tmux가 붙을 수 있게 하고, keepalive로 슬립/네트워크 전환 시 죽은 세션을 빨리 정리한다.
    static func remoteLaunchCommand(host: String, remoteScript: String) -> String {
        let remoteCommand = "bash -lc " + remoteScript.shQuoted
        return "exec ssh -t -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "
            + host.shQuoted + " -- " + remoteCommand.shQuoted
    }

    /// 원격 워크스페이스의 순수 셸 탭: 원격 디렉토리에서 로그인 셸.
    static func remoteShellCommand(host: String, remoteDirectory: RemoteDirectory) -> String {
        let script = "cd " + remoteDirectory.shellExpression + " 2>/dev/null; exec \"${SHELL:-bash}\" -l"
        return remoteLaunchCommand(host: host, remoteScript: script)
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
