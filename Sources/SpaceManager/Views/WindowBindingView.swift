import AppKit
import SwiftUI

enum WindowSurfacePolicy {
    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

enum WindowIdentity {
    private static let prefix = "SpaceManager.window."

    static func identifier(for stateID: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(prefix + stateID.uuidString.lowercased())
    }

    static func frameAutosaveName(for stateID: UUID) -> NSWindow.FrameAutosaveName {
        NSWindow.FrameAutosaveName(prefix + stateID.uuidString.lowercased())
    }
}

/// 저장 화면이 사라졌거나 해상도가 바뀌어도 창 전체를 현재 화면 안으로 옮긴다.
enum WindowFrameRestoration {
    static func fittedFrame(
        _ saved: CGRect,
        visibleFrames: [CGRect],
        fallbackVisibleFrame: CGRect?,
        minimumSize: CGSize
    ) -> CGRect {
        guard !visibleFrames.isEmpty || fallbackVisibleFrame != nil else { return saved }
        let fallback = fallbackVisibleFrame ?? visibleFrames[0]
        let target = visibleFrames.max { lhs, rhs in
            intersectionArea(saved, lhs) < intersectionArea(saved, rhs)
        }.flatMap { intersectionArea(saved, $0) > 0 ? $0 : nil } ?? fallback

        let width = min(max(saved.width, minimumSize.width), target.width)
        let height = min(max(saved.height, minimumSize.height), target.height)
        let x = min(max(saved.minX, target.minX), target.maxX - width)
        let y = min(max(saved.minY, target.minY), target.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

/// 창별 AppState를 실제 NSWindow에 연결하는 보이지 않는 브리지.
struct WindowBindingView: NSViewRepresentable {
    let appState: AppState
    let scanner: RecentActivityScanner
    let hover: IslandHoverState
    let title: String

    func makeNSView(context: Context) -> WindowBindingNSView {
        WindowBindingNSView(appState: appState, scanner: scanner, hover: hover, title: title)
    }

    func updateNSView(_ view: WindowBindingNSView, context: Context) {
        view.update(appState: appState, scanner: scanner, hover: hover, title: title)
    }

    static func dismantleNSView(_ view: WindowBindingNSView, coordinator: ()) {
        view.detach()
    }
}

final class WindowBindingNSView: NSView {
    private weak var appState: AppState?
    private weak var boundWindow: NSWindow?
    private var scanner: RecentActivityScanner
    private var hover: IslandHoverState
    private var title: String
    private var windowObservers: [NSObjectProtocol] = []
    private var pendingPresentationSave: DispatchWorkItem?

    init(appState: AppState, scanner: RecentActivityScanner, hover: IslandHoverState, title: String) {
        self.appState = appState
        self.scanner = scanner
        self.hover = hover
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(appState: AppState, scanner: RecentActivityScanner, hover: IslandHoverState, title: String) {
        self.appState = appState
        self.scanner = scanner
        self.hover = hover
        self.title = title
        bindIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindIfPossible()
    }

    func detach() {
        flushWindowPresentation()
        removeWindowObservers()
        if let boundWindow, let appState {
            WorkspaceWindowRegistry.shared.detach(window: boundWindow, from: appState)
        }
        boundWindow = nil
    }

    private func bindIfPossible() {
        guard let window, let appState else { return }
        if let boundWindow, boundWindow !== window {
            detach()
        }
        let isNewBinding = boundWindow !== window
        boundWindow = window

        if isNewBinding {
            // hiddenTitleBar 씬의 콘텐츠를 실제 프레임 상단까지 연장한다. 최상단의
            // 비어 있는 면은 창 드래그 영역으로 남고, SwiftUI의 pill/버튼처럼
            // hit-test되는 컨트롤은 정상적으로 이벤트를 받는다.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            WindowSurfacePolicy.configure(window)

            let identifier = WindowIdentity.identifier(for: appState.windowStateId)
            window.identifier = identifier
            window.setFrameAutosaveName(WindowIdentity.frameAutosaveName(for: appState.windowStateId))
            restoreWindowPresentation(window: window, appState: appState)
            installWindowObservers(for: window)
        }
        // titlebar가 보이지 않아도 Mission Control, Dock, 창 전환기는 이 값을 쓴다.
        // ContentView가 AppState 변경을 관찰해 updateNSView를 다시 호출하므로
        // 워크스페이스 전환과 같은 렌더 사이클에 창 제목도 갱신된다.
        window.title = title

        // full-size titlebar 설정과 무관하게 창별 AppState 바인딩은 유지한다.
        // 아일랜드의 다른 창 워크스페이스 점프가 이 연결을 사용한다.
        WorkspaceWindowRegistry.shared.attach(window: window, to: appState)
    }

    private func restoreWindowPresentation(window: NSWindow, appState: AppState) {
        if let saved = appState.restoredWindowFrame {
            let requested = CGRect(
                x: saved.x,
                y: saved.y,
                width: saved.width,
                height: saved.height
            )
            let minimumSize: CGSize = appState.windowKind == .quick
                ? CGSize(width: 760, height: 520)
                : CGSize(width: 900, height: 600)
            let fitted = WindowFrameRestoration.fittedFrame(
                requested,
                visibleFrames: NSScreen.screens.map(\.visibleFrame),
                fallbackVisibleFrame: NSScreen.main?.visibleFrame,
                minimumSize: minimumSize
            )
            if !window.styleMask.contains(.fullScreen) {
                window.setFrame(fitted, display: false)
            }
        }

        let wantsFullscreen = appState.restoredWindowIsFullscreen
        let wantsZoom = appState.restoredWindowIsZoomed && !wantsFullscreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            guard let self, let window, self.boundWindow === window else { return }
            let isFullscreen = window.styleMask.contains(.fullScreen)
            if wantsFullscreen != isFullscreen {
                window.toggleFullScreen(nil)
            } else if !wantsFullscreen && wantsZoom != window.isZoomed {
                window.zoom(nil)
            }
        }
    }

    private func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.scheduleWindowPresentationSave()
            }
        }
    }

    private func removeWindowObservers() {
        pendingPresentationSave?.cancel()
        pendingPresentationSave = nil
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func scheduleWindowPresentationSave() {
        pendingPresentationSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushWindowPresentation()
        }
        pendingPresentationSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func flushWindowPresentation() {
        pendingPresentationSave?.cancel()
        pendingPresentationSave = nil
        guard let window = boundWindow, let appState else { return }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        let isZoomed = !isFullscreen && window.isZoomed
        let frame: WindowFrameState? = (isFullscreen || isZoomed) ? nil : WindowFrameState(
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.size.width,
            height: window.frame.size.height
        )
        appState.updateWindowPresentation(
            frame: frame,
            isZoomed: isZoomed,
            isFullscreen: isFullscreen
        )
    }
}
