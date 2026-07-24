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
        WorkspaceWindowRegistry.shared.attach(window: window, to: appState)
    }
}
