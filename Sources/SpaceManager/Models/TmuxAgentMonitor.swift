import Foundation

/// 워크스페이스 tmux 세션 속 에이전트의 상태.
enum AgentState: Equatable {
    case working    // 출력이 흐르는 중 — 신경 꺼도 되는 상태
    case waiting    // 프롬프트에서 조용 — 유저의 답을 기다릴 가능성이 높은 상태
}

/// tmux 세션들의 에이전트 상태를 폴링한다.
///
/// 판별 원리: pane의 포그라운드 명령이 셸이면 에이전트가 없는 것이고,
/// 셸이 아니면(claude 등) 에이전트가 떠 있는 것이다. 그 위에서
/// window_activity(마지막 출력 시각)가 최근이면 "작업 중", 조용하면 "답변 대기".
/// Claude Code는 생성 중엔 스피너로 계속 출력을 만들고 입력 대기 중엔 화면이
/// 정지하므로 이 구분이 실사용에서 잘 맞는다.
///
/// 한계(의도된 단순화): 에이전트가 아닌 장시간 프로세스(dev 서버 등)도 조용하면
/// waiting으로 보인다 — 소음이 되면 pane_current_command == "claude" 화이트리스트로 좁힌다.
final class TmuxAgentMonitor: ObservableObject {
    static let shared = TmuxAgentMonitor()

    /// tmux 세션명 → 에이전트 상태. 에이전트 없는 세션은 키 자체가 없다.
    @Published private(set) var states: [String: AgentState] = [:]

    static let pollInterval: TimeInterval = 2.5
    /// 이 시간 안에 출력이 있었으면 "작업 중"
    static let workingThreshold: TimeInterval = 4
    /// working→waiting 전환에 필요한 연속 조용 폴 수 — 생성 중 잠깐의 침묵
    /// (툴 호출 대기 등)마다 점이 깜빡이면 산만하므로 히스테리시스를 둔다
    static let quietPollsForWaiting = 2

    private var timer: Timer?
    private let queue = DispatchQueue(label: "SpaceManager.AgentMonitor", qos: .utility)
    private var quietCounts: [String: Int] = [:]   // queue 위에서만 접근

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        // 서버가 없으면 폴링할 것도 없고, 콜드부트 창에는 tmux 프로세스를 띄우면
        // continuum 가드를 오판시킨다 (TmuxBootstrap.isInColdBootWindow 참조)
        guard TmuxBootstrap.serverSocketExists, !TmuxBootstrap.isInColdBootWindow,
              let tmux = TmuxBootstrap.tmuxPath else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard let output = Self.runTmux(tmux, ["list-panes", "-a", "-F",
                "#{session_name}\t#{window_activity}\t#{pane_current_command}"]) else {
                DispatchQueue.main.async { if !self.states.isEmpty { self.states = [:] } }
                return
            }
            let snapshot = Self.sessionSnapshot(samples: Self.parseSamples(output))
            let next = Self.nextStates(
                snapshot: snapshot,
                previous: self.states,
                quietCounts: &self.quietCounts,
                now: Date().timeIntervalSince1970
            )
            DispatchQueue.main.async {
                if self.states != next { self.states = next }
            }
        }
    }

    private static func runTmux(_ tmux: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 순수 로직 (테스트 대상)

    struct PaneSample: Equatable {
        let session: String
        let activity: TimeInterval   // epoch seconds
        let command: String
    }

    static let shellCommands: Set<String> = ["zsh", "bash", "sh", "fish", "-zsh", "-bash", "login"]

    static func parseSamples(_ output: String) -> [PaneSample] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let activity = TimeInterval(parts[1]) else { return nil }
            return PaneSample(session: String(parts[0]), activity: activity, command: String(parts[2]))
        }
    }

    /// 세션 단위로 접기 — 활동 시각은 최댓값, 에이전트 존재는 "셸 아닌 pane 하나라도"
    static func sessionSnapshot(samples: [PaneSample]) -> [String: (lastActivity: TimeInterval, hasAgent: Bool)] {
        var result: [String: (TimeInterval, Bool)] = [:]
        for sample in samples {
            let isAgent = !shellCommands.contains(sample.command)
            let prev = result[sample.session] ?? (0, false)
            result[sample.session] = (max(prev.0, sample.activity), prev.1 || isAgent)
        }
        return result
    }

    static func nextStates(
        snapshot: [String: (lastActivity: TimeInterval, hasAgent: Bool)],
        previous: [String: AgentState],
        quietCounts: inout [String: Int],
        now: TimeInterval
    ) -> [String: AgentState] {
        var result: [String: AgentState] = [:]
        for (session, info) in snapshot {
            guard info.hasAgent else {
                quietCounts[session] = nil
                continue
            }
            if now - info.lastActivity <= workingThreshold {
                result[session] = .working
                quietCounts[session] = 0
            } else {
                let quiet = (quietCounts[session] ?? 0) + 1
                quietCounts[session] = quiet
                // 방금까지 작업 중이었다면 유예를 거쳐야 waiting — 깜빡임 방지.
                // 처음 보는 조용한 에이전트는 바로 waiting (앱 시작 시 지연 없이 표시)
                if previous[session] == .working && quiet < quietPollsForWaiting {
                    result[session] = .working
                } else {
                    result[session] = .waiting
                }
            }
        }
        // 사라진 세션의 카운터 정리
        quietCounts = quietCounts.filter { snapshot[$0.key] != nil }
        return result
    }
}
