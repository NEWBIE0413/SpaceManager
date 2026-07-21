import SwiftUI
import AppKit

extension Color {
    /// Warm pink for active/selected text
    static let warmPink = Color(red: 0.95, green: 0.45, blue: 0.50)
    /// Slightly muted warm pink for section headers
    static let warmPinkMuted = Color(red: 0.78, green: 0.48, blue: 0.50)
}

/// 사이드바 공통 룩 — 행 높이·아이콘 크기·라운딩을 한 곳에서 통일한다.
/// 섹션마다 수치가 조금씩 다르면 패널 전체가 미묘하게 어수선해 보인다.
enum Sidebar {
    static let rowCornerRadius: CGFloat = 6
    static let rowVerticalPadding: CGFloat = 6
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 13
    static let iconFrame: CGFloat = 16

    static func rowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: rowCornerRadius)
            .fill(isSelected ? Color.primary.opacity(0.08)
                             : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
    }
}

/// 사이드바 섹션 헤더 — WORKSPACES / FILES가 같은 얼굴을 갖도록 공용화.
/// trailing에는 섹션의 대표 액션 하나만 놓는다 (액션이 늘면 메뉴로 접는다).
struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundColor(.warmPinkMuted)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
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
