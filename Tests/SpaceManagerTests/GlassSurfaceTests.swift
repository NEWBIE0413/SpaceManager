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
        XCTAssertEqual(glass.state, .active)
        XCTAssertEqual(glass.material, .sidebar)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(glass.subviews.contains { $0 is NSGlassEffectView })
        }
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
        XCTAssertLessThan(
            GlassSurfacePolicy.tintColor(for: .canvasLight).alphaComponent,
            GlassSurfacePolicy.tintColor(for: .quickSidebar).alphaComponent
        )
        XCTAssertLessThan(
            GlassSurfacePolicy.tintColor(for: .canvasDark).alphaComponent,
            GlassSurfacePolicy.tintColor(for: .workspaceSidebar).alphaComponent
        )
        XCTAssertLessThan(
            GlassSurfacePolicy.surfaceOpacity(for: .canvasLight),
            GlassSurfacePolicy.surfaceOpacity(for: .quickSidebar)
        )
        XCTAssertLessThan(
            GlassSurfacePolicy.surfaceOpacity(for: .workspaceSidebar),
            1
        )
        XCTAssertEqual(GlassSurfacePolicy.cornerRadius(for: .quickSidebar), 16)
        XCTAssertEqual(GlassSurfacePolicy.cornerRadius(for: .canvasLight), 0)
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
