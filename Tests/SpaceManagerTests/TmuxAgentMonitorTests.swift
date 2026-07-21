import XCTest
@testable import SpaceManager

final class TmuxAgentMonitorTests: XCTestCase {
    func testParseSamples() {
        let out = "flat\t1750000000\tclaude\nflat\t1750000005\tzsh\nbad-line\n"
        let samples = TmuxAgentMonitor.parseSamples(out)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0], .init(session: "flat", activity: 1_750_000_000, command: "claude"))
    }

    // 셸만 있는 세션은 에이전트 없음, 활동 시각은 pane들의 최댓값이어야 한다
    func testSessionSnapshotAggregation() {
        let snapshot = TmuxAgentMonitor.sessionSnapshot(samples: [
            .init(session: "flat", activity: 100, command: "claude"),
            .init(session: "flat", activity: 200, command: "zsh"),
            .init(session: "idle", activity: 300, command: "zsh"),
        ])
        XCTAssertEqual(snapshot["flat"]?.lastActivity, 200)
        XCTAssertEqual(snapshot["flat"]?.hasAgent, true)
        XCTAssertEqual(snapshot["idle"]?.hasAgent, false)
    }

    func testRecentActivityIsWorkingAndShellSessionsAreAbsent() {
        var quiet: [String: Int] = [:]
        let states = TmuxAgentMonitor.nextStates(
            snapshot: ["flat": (lastActivity: 998, hasAgent: true),
                       "idle": (lastActivity: 998, hasAgent: false)],
            previous: [:], quietCounts: &quiet, now: 1000
        )
        XCTAssertEqual(states["flat"], .working)
        XCTAssertNil(states["idle"])
    }

    // 처음 관측된 조용한 에이전트는 유예 없이 바로 waiting — 앱 시작 직후에도
    // "주의 필요" 세션이 즉시 보여야 한다
    func testQuietAgentWithNoHistoryIsWaitingImmediately() {
        var quiet: [String: Int] = [:]
        let states = TmuxAgentMonitor.nextStates(
            snapshot: ["flat": (lastActivity: 0, hasAgent: true)],
            previous: [:], quietCounts: &quiet, now: 1000
        )
        XCTAssertEqual(states["flat"], .waiting)
    }

    // working→waiting은 조용한 폴 2회를 요구한다 (생성 중 잠깐의 침묵에 깜빡이지 않게)
    func testWorkingToWaitingRequiresConsecutiveQuietPolls() {
        var quiet: [String: Int] = [:]
        let snapshotQuiet: [String: (lastActivity: TimeInterval, hasAgent: Bool)] =
            ["flat": (lastActivity: 0, hasAgent: true)]

        let first = TmuxAgentMonitor.nextStates(
            snapshot: snapshotQuiet, previous: ["flat": .working], quietCounts: &quiet, now: 1000)
        XCTAssertEqual(first["flat"], .working, "첫 조용 폴에서는 아직 working 유지")

        let second = TmuxAgentMonitor.nextStates(
            snapshot: snapshotQuiet, previous: first, quietCounts: &quiet, now: 1002)
        XCTAssertEqual(second["flat"], .waiting, "연속 두 번 조용하면 waiting")
    }

    // 다시 출력이 흐르면 즉시 working으로 복귀하고 조용 카운터가 리셋되어야 한다
    func testActivityResetsQuietCounter() {
        var quiet: [String: Int] = ["flat": 1]
        let states = TmuxAgentMonitor.nextStates(
            snapshot: ["flat": (lastActivity: 999, hasAgent: true)],
            previous: ["flat": .waiting], quietCounts: &quiet, now: 1000
        )
        XCTAssertEqual(states["flat"], .working)
        XCTAssertEqual(quiet["flat"], 0)
    }
}
