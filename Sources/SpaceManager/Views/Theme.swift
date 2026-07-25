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
    static let rowCornerRadius: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 12
    static let iconSize: CGFloat = 13
    static let iconFrame: CGFloat = 16
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

/// 헤르메스(Quick) 창 전용 사이드바 섹션 헤더 — claude.ai 데스크톱 감성(작고 옅은 라벨 위계)
struct QuickSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundColor(.secondary.opacity(0.85))
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// 라이트/다크는 창별이다 — ContentView의 preferredColorScheme이 창(씬) 단위로
/// 적용한다. 여기는 tmux 쪽 연동만 남는다.
enum AppearanceManager {
    /// 앱 무드를 tmux 상태바까지 연장한다 (~/.smux/bin/smux-theme).
    ///
    /// 라이트로 갈 때만 soft를 호출한다 — 문제의 본질이 "화이트 크롬 위의 솔리드
    /// pill 충돌"이고, 다크에서의 취향은 유저마다 갈리는 영역이라(현재 SEOL은
    /// 다크에서도 soft 선호) 다크 전환 시 강제로 pill을 씌우면 취향과 싸우는
    /// 동기화가 된다. 다크에서 pill을 원하게 되면 호출부에 else 분기로 dark 추가.
    /// tmux 상태바는 전역이므로, 유저가 마지막으로 토글한 창의 무드를 따른다.
    static func syncTmuxThemeToSoft() {
        // 콜드부트 창에는 어떤 tmux 명령도 금지 (continuum 가드 오판 방지)
        guard TmuxBootstrap.serverSocketExists, !TmuxBootstrap.isInColdBootWindow else { return }
        let switcher = NSHomeDirectory() + "/.smux/bin/smux-theme"
        guard FileManager.default.isExecutableFile(atPath: switcher) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: switcher)
            process.arguments = ["soft"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()   // best-effort — 실패해도 앱 테마 전환은 이미 완료
        }
    }
}
