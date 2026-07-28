import AppKit
import XCTest
@testable import SpaceManager

final class WindowRestorationTests: XCTestCase {
    func testWindowIdentityIsStableAndDistinct() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            WindowIdentity.identifier(for: first).rawValue,
            WindowIdentity.frameAutosaveName(for: first)
        )
        XCTAssertNotEqual(
            WindowIdentity.identifier(for: first),
            WindowIdentity.identifier(for: second)
        )
    }

    func testVisibleSavedFrameIsUnchanged() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let saved = CGRect(x: 200, y: 120, width: 1100, height: 720)
        XCTAssertEqual(
            WindowFrameRestoration.fittedFrame(
                saved,
                visibleFrames: [screen],
                fallbackVisibleFrame: screen,
                minimumSize: CGSize(width: 900, height: 600)
            ),
            saved
        )
    }

    func testOffscreenFrameMovesIntoFallbackScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let fitted = WindowFrameRestoration.fittedFrame(
            CGRect(x: 9000, y: -4000, width: 1200, height: 800),
            visibleFrames: [screen],
            fallbackVisibleFrame: screen,
            minimumSize: CGSize(width: 900, height: 600)
        )
        XCTAssertTrue(screen.contains(fitted))
        XCTAssertEqual(fitted.size, CGSize(width: 1200, height: 800))
    }

    func testFrameUsesDisplayWithLargestIntersectionAndClampsEdges() {
        let left = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let fitted = WindowFrameRestoration.fittedFrame(
            CGRect(x: -200, y: 100, width: 1000, height: 700),
            visibleFrames: [left, right],
            fallbackVisibleFrame: right,
            minimumSize: CGSize(width: 900, height: 600)
        )
        XCTAssertTrue(right.contains(fitted))
        XCTAssertEqual(fitted.origin.x, 0)
    }

    func testOversizedFrameShrinksToVisibleBounds() {
        let screen = CGRect(x: 100, y: 50, width: 1280, height: 720)
        let fitted = WindowFrameRestoration.fittedFrame(
            CGRect(x: -1000, y: -1000, width: 4000, height: 3000),
            visibleFrames: [screen],
            fallbackVisibleFrame: screen,
            minimumSize: CGSize(width: 900, height: 600)
        )
        XCTAssertEqual(fitted, screen)
    }
}
