import AppKit

/// Shared visibility signal. A visible background window still needs fresh data;
/// closing, minimizing or covering every window suspends display-only work.
final class AppResourcePolicy {
    static let shared = AppResourcePolicy()
    private var observers: [NSObjectProtocol] = []
    private var listeners: [UUID: (Bool) -> Void] = [:]
    private(set) var hasVisibleWindows = false

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose is delivered before the window leaves NSApp.windows.
                DispatchQueue.main.async { self?.refresh() }
            })
        }
    }

    static func isVisible(isVisible: Bool, isMiniaturized: Bool, isOccluded: Bool) -> Bool {
        isVisible && !isMiniaturized && !isOccluded
    }

    func observe(_ id: UUID, change: @escaping (Bool) -> Void) {
        refresh()
        listeners[id] = change
        change(hasVisibleWindows)
    }

    func removeObserver(_ id: UUID) { listeners[id] = nil }

    private func refresh() {
        let visible = NSApp?.windows.contains {
            Self.isVisible(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized,
                           isOccluded: !$0.occlusionState.contains(.visible))
        } ?? false
        guard visible != hasVisibleWindows else { return }
        hasVisibleWindows = visible
        for listener in Array(listeners.values) { listener(visible) }
    }
}
