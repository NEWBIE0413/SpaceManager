import AppKit
import SwiftUI

enum WindowSurfacePolicy {
    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
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
        if let boundWindow, let appState {
            WorkspaceWindowRegistry.shared.detach(window: boundWindow, from: appState)
        }
        boundWindow = nil
    }

    private func bindIfPossible() {
        guard let window, let appState else { return }
        if let boundWindow, boundWindow !== window {
            WorkspaceWindowRegistry.shared.detach(window: boundWindow, from: appState)
        }
        boundWindow = window

        // hiddenTitleBar 씬의 콘텐츠를 실제 프레임 상단까지 연장한다. 최상단의
        // 비어 있는 면은 창 드래그 영역으로 남고, SwiftUI의 pill/버튼처럼
        // hit-test되는 컨트롤은 정상적으로 이벤트를 받는다.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        WindowSurfacePolicy.configure(window)
        // titlebar가 보이지 않아도 Mission Control, Dock, 창 전환기는 이 값을 쓴다.
        // ContentView가 AppState 변경을 관찰해 updateNSView를 다시 호출하므로
        // 워크스페이스 전환과 같은 렌더 사이클에 창 제목도 갱신된다.
        window.title = title

        // full-size titlebar 설정과 무관하게 창별 AppState 바인딩은 유지한다.
        // 아일랜드의 다른 창 워크스페이스 점프가 이 연결을 사용한다.
        WorkspaceWindowRegistry.shared.attach(window: window, to: appState)
    }
}
