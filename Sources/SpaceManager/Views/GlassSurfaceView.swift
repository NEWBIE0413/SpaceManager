import AppKit
import SwiftUI

enum GlassSurfaceRole: Equatable {
    case canvasDark
    case canvasLight
    case workspaceSidebar
    case quickSidebar
}

/// behind-window blur와 tint를 역할별로 고정한다. 캔버스는 최대한 옅게,
/// 사이드바는 한 단계 진하게 두어 같은 유리 안에서도 정보 위계가 남는다.
enum GlassSurfacePolicy {
    static func material(for role: GlassSurfaceRole) -> NSVisualEffectView.Material {
        switch role {
        case .canvasDark, .canvasLight:
            return .underWindowBackground
        case .workspaceSidebar, .quickSidebar:
            return .sidebar
        }
    }

    static func tintColor(for role: GlassSurfaceRole) -> NSColor {
        switch role {
        case .canvasDark:
            return NSColor(srgbRed: 0.035, green: 0.04, blue: 0.05, alpha: 0.18)
        case .canvasLight:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        case .workspaceSidebar:
            return NSColor(srgbRed: 0.025, green: 0.028, blue: 0.035, alpha: 0.58)
        case .quickSidebar:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.38)
        }
    }

    static func usesClearNativeGlass(for role: GlassSurfaceRole) -> Bool {
        switch role {
        case .canvasDark, .canvasLight:
            return true
        case .workspaceSidebar, .quickSidebar:
            return false
        }
    }

    static func cornerRadius(for role: GlassSurfaceRole) -> CGFloat {
        switch role {
        case .canvasDark, .canvasLight:
            return 0
        case .workspaceSidebar, .quickSidebar:
            return 16
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

/// `NSVisualEffectView.behindWindow`로 데스크톱 샘플링을 보장하고, macOS 26+
/// native glass를 얹어 시스템의 동적 굴절과 하이라이트를 사용한다.
final class BehindWindowGlassNSView: NSVisualEffectView {
    private var nativeGlassView: NSView?

    init(role: GlassSurfaceRole) {
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        configure(role: role)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(role: GlassSurfaceRole) {
        material = GlassSurfacePolicy.material(for: role)

        if #available(macOS 26.0, *) {
            let glass: NSGlassEffectView
            if let existing = nativeGlassView as? NSGlassEffectView {
                glass = existing
            } else {
                nativeGlassView?.removeFromSuperview()
                glass = NSGlassEffectView(frame: .zero)
                glass.translatesAutoresizingMaskIntoConstraints = false
                addSubview(glass)
                NSLayoutConstraint.activate([
                    glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                    glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                    glass.topAnchor.constraint(equalTo: topAnchor),
                    glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                nativeGlassView = glass
            }
            glass.style = GlassSurfacePolicy.usesClearNativeGlass(for: role) ? .clear : .regular
            glass.tintColor = GlassSurfacePolicy.tintColor(for: role)
            glass.cornerRadius = GlassSurfacePolicy.cornerRadius(for: role)
        }
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
