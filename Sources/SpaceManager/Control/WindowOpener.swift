import SwiftUI

/// SwiftUI의 `openWindow`는 뷰 환경 밖에서 부를 수 없다. 창이 하나라도 떠 있으면 그 창의
/// ContentView가 자기 openWindow 액션을 여기에 걸어두고, CLI는 이걸로 새 창을 연다.
@MainActor
enum WindowOpener {
    static var open: ((_ sceneID: String, _ id: UUID) -> Void)?

    static func register(_ action: OpenWindowAction) {
        open = { sceneID, id in action(id: sceneID, value: id) }
    }
}
