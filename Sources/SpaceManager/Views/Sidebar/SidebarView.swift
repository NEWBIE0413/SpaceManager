import SwiftUI

/// Left sidebar containing workspaces and projects.
/// 라이트 모드에서도 딥 다크를 유지한다 — 아일랜드의 "완전 다크"를 패널로 연장한
/// 디자인 결정. 컬러스킴을 다크로 고정하면 .primary/.secondary/선택 배경이 전부
/// 다크 기준으로 풀리므로 개별 색을 손볼 필요가 없다.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isCompact: Bool
    @State private var isHoveringTheme = false

    private var isDarkNow: Bool {
        switch appState.preferredAppearance {
        case "light": return false
        case "dark": return true
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("WORKSPACES")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(isCompact ? 0 : 1)
                    .frame(width: isCompact ? 0 : nil, alignment: .leading)
                    .clipped()
                    .accessibilityHidden(isCompact)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button {
                        appState.showNewWorkspaceSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: Sidebar.iconSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Workspace")
                    .accessibilityLabel("New Workspace")
                    themeToggle
                }
                .opacity(isCompact ? 0 : 1)
                .frame(width: isCompact ? 0 : nil)
                .clipped()
                .allowsHitTesting(!isCompact)
                .accessibilityHidden(isCompact)
                sidebarToggle
                    .padding(.leading, isCompact ? 0 : 4)
            }
            .frame(height: 24)
            .padding(.horizontal, isCompact ? 17 : 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Workspaces section — 고정 높이 + 자체 스크롤 (워크스페이스가 많아도 영역 불변)
            ScrollView {
                WorkspaceListView(isCompact: isCompact)
            }
            .frame(height: isCompact ? nil : 320)
            .frame(maxHeight: isCompact ? .infinity : nil)

            if !isCompact {
                Divider()
                    .padding(.vertical, 8)

                // Projects section (for selected workspace)
                ProjectListView()

                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .background(BehindWindowGlassSurface(role: .workspaceSidebar))
        .environment(\.colorScheme, .dark)
    }

    private var themeToggle: some View {
        Button {
            appState.setAppearance(isDarkNow ? "light" : "dark")
        } label: {
            Image(systemName: isDarkNow ? "sun.max" : "moon")
                .font(.system(size: Sidebar.iconSize, weight: .medium))
                .foregroundStyle(isHoveringTheme ? Color.primary : Color.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringTheme = $0 }
        .help(isDarkNow ? "라이트 모드로 전환" : "다크 모드로 전환")
        .accessibilityLabel(isDarkNow ? "Light Mode" : "Dark Mode")
    }

    private var sidebarToggle: some View {
        Button {
            isCompact.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCompact ? "사이드패널 펼치기" : "사이드패널 접기")
        .accessibilityLabel(isCompact ? "Expand Sidebar" : "Collapse Sidebar")
    }
}
