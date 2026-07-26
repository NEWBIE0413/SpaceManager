import AppKit
import SwiftUI

enum GlassSurfaceRole: Equatable {
    case canvasDark
    case canvasLight
    case workspaceSidebar
    case quickSidebar
}

/// 캔버스는 불투명 단색, 사이드바만 behind-window blur를 사용한다.
enum GlassSurfacePolicy {
    static func canvasColor(for windowKind: WindowKind, isDark: Bool) -> NSColor {
        if windowKind == .quick {
            return .windowBackgroundColor
        }
        return canvasColor(for: isDark ? .canvasDark : .canvasLight)
    }

    static func material(for role: GlassSurfaceRole) -> NSVisualEffectView.Material {
        switch role {
        case .canvasDark, .canvasLight:
            return .underWindowBackground
        case .workspaceSidebar, .quickSidebar:
            return .sidebar
        }
    }

    static func canvasColor(for role: GlassSurfaceRole) -> NSColor {
        switch role {
        case .canvasDark:
            return .windowBackgroundColor
        case .canvasLight:
            return NSColor(srgbRed: 0.98, green: 0.976, blue: 0.96, alpha: 1)
        case .workspaceSidebar, .quickSidebar:
            preconditionFailure("Sidebar roles do not have a canvas color")
        }
    }

    /// WKWebView는 drawsBackground=false이므로 카드가 직접 팔레트 배경을 막는다.
    static func terminalCardColor(for windowKind: WindowKind) -> NSColor {
        switch windowKind {
        case .workspace:
            return NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
        case .quick:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

/// 사이드바 한 겹만 `NSVisualEffectView.behindWindow`로 데스크톱을 샘플링한다.
/// 비활성 창에서는 followsWindowActiveState가 블러 합성 비용을 멈춘다.
final class BehindWindowGlassNSView: NSVisualEffectView {
    init(role: GlassSurfaceRole) {
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        isEmphasized = false
        configure(role: role)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(role: GlassSurfaceRole) {
        material = GlassSurfacePolicy.material(for: role)
    }
}

struct BehindWindowGlassSurface: NSViewRepresentable {
    let role: GlassSurfaceRole

    func makeNSView(context: Context) -> BehindWindowGlassNSView {
        BehindWindowGlassNSView(role: role)
    }

    func updateNSView(_ view: BehindWindowGlassNSView, context: Context) {
        view.configure(role: role)
    }
}
