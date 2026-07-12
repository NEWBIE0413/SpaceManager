import Foundation

extension Notification.Name {
    /// 터미널 클릭 시 해당 탭 선택 요청 (ManagedTerminalView가 게시)
    static let agentSelectionRequested = Notification.Name("agentSelectionRequested")
}
