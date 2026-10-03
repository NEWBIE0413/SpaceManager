import AppKit
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

final class ActivitySpinnerViewTests: XCTestCase {
    /// 생성 중 행의 스피너 위를 눌러도 행 선택이 되고 창이 끌리지 않아야 한다.
    func testSpinnerNeverCapturesPointer() {
        let spinner = ActivitySpinnerView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        container.addSubview(spinner)
        XCTAssertNil(spinner.hitTest(NSPoint(x: 6, y: 6)))
        XCTAssertTrue(container.hitTest(NSPoint(x: 6, y: 6)) === container)
    }
}
