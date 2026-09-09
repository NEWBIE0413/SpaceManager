import XCTest
@testable import SpaceManager

final class AppResourcePolicyTests: XCTestCase {
    func testBackgroundVisibleWindowStillUpdatesButCoveredAndMinimizedWindowsDoNot() {
        XCTAssertTrue(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: false, isOccluded: false))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: true, isOccluded: false))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: false, isOccluded: true))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: false, isMiniaturized: false, isOccluded: false))
    }

    func testClosingOneWindowKeepsSharedScannersAliveUntilLastConsumerLeaves() {
        let first = UUID(), second = UUID(), session = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activity = RecentActivityScanner(projectsDir: directory,
            codexSessionsDir: directory, geminiDir: directory)
        let quick = QuickConversationScanner(transcriptsDirectory: directory)
        activity.start(owner: first)
        activity.start(owner: second)
        quick.start(owner: first)
        quick.start(owner: second)
        quick.track(sessionID: "session", owner: session)
        activity.stop(owner: first)
        quick.stop(owner: first)
        XCTAssertTrue(activity.isStarted)
        XCTAssertTrue(quick.isStarted)
        activity.stop(owner: second)
        quick.stop(owner: second)
        XCTAssertFalse(activity.isStarted)
        XCTAssertTrue(quick.isStarted, "A tracked terminal still needs its title")
        quick.untrack(owner: session)
        XCTAssertFalse(quick.isStarted)
    }
}
