import AppKit
import SwiftUI

/// 창별 AppState를 실제 NSWindow에 연결하는 보이지 않는 브리지.
struct WindowBindingView: NSViewRepresentable {
    let appState: AppState
    let scanner: RecentActivityScanner
    let hover: IslandHoverState

    func makeNSView(context: Context) -> WindowBindingNSView {
        WindowBindingNSView(appState: appState, scanner: scanner, hover: hover)
    }

    func updateNSView(_ view: WindowBindingNSView, context: Context) {
        view.update(appState: appState, scanner: scanner, hover: hover)
    }

    static func dismantleNSView(_ view: WindowBindingNSView, coordinator: ()) {
        view.detach()
    }
}

final class WindowBindingNSView: NSView {
    private weak var appState: AppState?
    private weak var boundWindow: NSWindow?
    private var overlay: TitlebarIslandOverlayView?
    private var scanner: RecentActivityScanner
    private var hover: IslandHoverState

    init(appState: AppState, scanner: RecentActivityScanner, hover: IslandHoverState) {
        self.appState = appState
        self.scanner = scanner
        self.hover = hover
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(appState: AppState, scanner: RecentActivityScanner, hover: IslandHoverState) {
        self.appState = appState
        self.scanner = scanner
        self.hover = hover
        overlay?.update(scanner: scanner, hover: hover)
        bindIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindIfPossible()
    }

    func detach() {
        if let boundWindow, let appState {
            WorkspaceWindowRegistry.shared.detach(window: boundWindow, from: appState)
        }
        overlay?.removeFromSuperview()
        overlay = nil
        boundWindow = nil
    }

    private func bindIfPossible() {
        guard let window, let appState else { return }
        if let boundWindow, boundWindow !== window {
            WorkspaceWindowRegistry.shared.detach(window: boundWindow, from: appState)
            overlay?.removeFromSuperview()
            overlay = nil
        }
        boundWindow = window
        WorkspaceWindowRegistry.shared.attach(window: window, to: appState)
        installOverlay(in: window)
    }

    private func installOverlay(in window: NSWindow) {
        guard overlay == nil, let frameView = window.contentView?.superview else { return }
        let titlebarHeight = max(38, frameView.bounds.height - window.contentLayoutRect.height)
        let overlay = TitlebarIslandOverlayView(scanner: scanner, hover: hover)
        overlay.frame = NSRect(
            x: 0,
            y: frameView.bounds.maxY - titlebarHeight,
            width: frameView.bounds.width,
            height: titlebarHeight
        )
        overlay.autoresizingMask = [.width, .minYMargin]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
    }
}

/// 사이드바와 detail을 모두 가로지르는 투명 타이틀바 레이어. 중앙 pill 영역만
/// 이벤트를 받고 나머지는 nil을 반환해 창 드래그, 신호등, toolbar 버튼으로 통과시킨다.
final class TitlebarIslandOverlayView: NSView {
    private let host: NSHostingView<IslandPillView>

    init(scanner: RecentActivityScanner, hover: IslandHoverState) {
        host = NSHostingView(rootView: IslandPillView(scanner: scanner, hover: hover))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(scanner: RecentActivityScanner, hover: IslandHoverState) {
        host.rootView = IslandPillView(scanner: scanner, hover: hover)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = host.fittingSize
        host.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hostPoint = host.convert(point, from: self)
        guard host.bounds.contains(hostPoint) else { return nil }
        return host.hitTest(hostPoint)
    }
}
