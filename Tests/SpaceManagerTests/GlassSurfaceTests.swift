import AppKit
import XCTest
@testable import SpaceManager

final class GlassSurfaceTests: XCTestCase {
    func testWindowAndGlassConfiguration() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        WindowSurfacePolicy.configure(window)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)

        let glass = BehindWindowGlassNSView(role: .workspaceSidebar)
        XCTAssertEqual(glass.blendingMode, .behindWindow)
        XCTAssertEqual(glass.state, .followsWindowActiveState)
        XCTAssertEqual(glass.material, .sidebar)
        XCTAssertTrue(glass.subviews.isEmpty)
    }

    func testSurfacePolicies() {
        XCTAssertEqual(
            GlassSurfacePolicy.material(for: .canvasDark),
            .underWindowBackground
        )
        XCTAssertEqual(
            GlassSurfacePolicy.material(for: .quickSidebar),
            .sidebar
        )
        XCTAssertEqual(GlassSurfacePolicy.canvasColor(for: .canvasDark), .windowBackgroundColor)
        XCTAssertEqual(GlassSurfacePolicy.canvasColor(for: .canvasLight).alphaComponent, 1)
        XCTAssertEqual(
            GlassSurfacePolicy.terminalCardColor(for: .workspace).alphaComponent,
            1
        )
        XCTAssertEqual(
            GlassSurfacePolicy.terminalCardColor(for: .quick).alphaComponent,
            1
        )
    }
}
