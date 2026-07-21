import XCTest
@testable import SpaceManager

final class WorkspaceActivityDotTests: XCTestCase {
    func testRecencyOpacityUsesShortHalfLife() throws {
        let now = try XCTUnwrap(WorkspaceActivityDot.recencyOpacity(age: 0))
        let threeHours = try XCTUnwrap(WorkspaceActivityDot.recencyOpacity(age: 3 * 3600))
        let twelveHours = try XCTUnwrap(WorkspaceActivityDot.recencyOpacity(age: 12 * 3600))
        let almostYesterday = try XCTUnwrap(WorkspaceActivityDot.recencyOpacity(age: 23 * 3600))

        XCTAssertEqual(now, 1, accuracy: 0.001)
        XCTAssertEqual(threeHours, 0.627, accuracy: 0.01)
        XCTAssertEqual(twelveHours, 0.195, accuracy: 0.01)
        XCTAssertEqual(almostYesterday, 0.097, accuracy: 0.01)
        XCTAssertGreaterThan(now, threeHours)
        XCTAssertGreaterThan(threeHours, twelveHours)
        XCTAssertGreaterThan(twelveHours, almostYesterday)
    }

    func testRecencyOpacityDisappearsAtTwentyFourHours() {
        XCTAssertNotNil(WorkspaceActivityDot.recencyOpacity(age: RecentActivityScanner.dotWindow - 1))
        XCTAssertNil(WorkspaceActivityDot.recencyOpacity(age: RecentActivityScanner.dotWindow))
        XCTAssertNil(WorkspaceActivityDot.recencyOpacity(age: -1))
    }
}
