import Foundation

/// 헤르메스 창의 일상 대화 탭 규칙. q-N은 창 안의 표시명일 뿐 tmux 세션명이 아니다.
enum QuickSessionPolicy {
    static let launchCommand = "exec ccv -y"

    static func nextName(usedNames: Set<String>) -> String {
        var number = 1
        while usedNames.contains("q-\(number)") {
            number += 1
        }
        return "q-\(number)"
    }
}
