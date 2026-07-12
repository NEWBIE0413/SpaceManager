import SwiftUI
import AppKit

extension Color {
    /// Warm pink for active/selected text
    static let warmPink = Color(red: 0.95, green: 0.45, blue: 0.50)
    /// Slightly muted warm pink for section headers
    static let warmPinkMuted = Color(red: 0.78, green: 0.48, blue: 0.50)
}

/// 라이트/다크 오버라이드 — NSApp.appearance를 바꾸면 SwiftUI 색상과
/// 터미널 테마(viewDidChangeEffectiveAppearance)가 전부 자동 추종한다.
enum AppearanceManager {
    static func apply(_ raw: String) {
        switch raw {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil   // 시스템 추종
        }
    }

    static func applySaved() {
        apply(UserDefaults.standard.string(forKey: "preferredAppearance") ?? "system")
    }
}
