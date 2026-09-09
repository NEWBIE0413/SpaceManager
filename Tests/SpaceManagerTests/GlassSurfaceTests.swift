import AppKit
import XCTest
@testable import SpaceManager

final class GlassSurfaceTests: XCTestCase {
    func testWorkspaceHidesWindowButtonsAndQuickKeepsNativeControls() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        XCTAssertEqual(buttons.count, 3)
        WindowSurfacePolicy.updateWindowControls(window, kind: .workspace)
        XCTAssertTrue(buttons.allSatisfy(\.isHidden))
        // AppKit can reveal buttons when it rebuilds the titlebar.
        buttons[0].isHidden = false
        WindowSurfacePolicy.updateWindowControls(window, kind: .workspace)
        XCTAssertTrue(buttons.allSatisfy(\.isHidden))
        WindowSurfacePolicy.updateWindowControls(window, kind: .quick)
        XCTAssertTrue(buttons.allSatisfy { !$0.isHidden })
    }

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
        let darkCanvas = GlassSurfacePolicy.canvasColor(for: .canvasDark)
        XCTAssertLessThan(darkCanvas.redComponent, 0.06)
        XCTAssertLessThan(darkCanvas.greenComponent, 0.07)
        XCTAssertEqual(GlassSurfacePolicy.canvasColor(for: .canvasLight).alphaComponent, 1)
        XCTAssertEqual(
            GlassSurfacePolicy.canvasColor(for: .quick, isDark: false),
            .windowBackgroundColor
        )
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
