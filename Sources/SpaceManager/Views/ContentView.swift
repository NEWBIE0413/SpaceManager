import SwiftUI
import AppKit

/// Main content view with two-pane layout.
/// 창마다 하나씩 생성된다 — AppState가 여기 살아야 창별 독립 선택이 가능하다.
struct ContentView: View {
    private let windowKind: WindowKind
    @StateObject private var appState: AppState
    @ObservedObject private var activityScanner = RecentActivityScanner.shared
    @StateObject private var islandHover = IslandHoverState()
    @Environment(\.openWindow) private var openWindow

    init(windowKind: WindowKind = .workspace) {
        self.windowKind = windowKind
        _appState = StateObject(wrappedValue: AppState(windowKind: windowKind))
    }

    private var isDarkNow: Bool {
        switch appState.preferredAppearance {
        case "light": return false
        case "dark": return true
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// 창별 라이트/다크 — preferredColorScheme은 이 창(씬) 전체에 적용된다
    /// (타이틀바 텍스트·툴바·시트 포함). nil이면 시스템 추종.
    private var preferredScheme: ColorScheme? {
        if windowKind == .quick { return .light }
        switch appState.preferredAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 메인 캔버스 배경 (다크모드/라이트모드 대응)
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            
            HStack(spacing: 12) {
                Group {
                    if windowKind == .quick {
                        // 전용 목록은 다음 구현 단위에서 붙인다. 창 종류 저장/복원
                        // 경계부터 독립시켜 일반 창 상태를 잘못 claim하지 않게 한다.
                        SidebarView()
                    } else {
                        SidebarView()
                    }
                }
                    .frame(width: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                
                TerminalAreaView()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(isDarkNow ? 0.3 : 0.1), radius: 8, x: 0, y: 4)
            }
            // 캔버스 인셋: 신호등(Traffic Lights) 겹침 방지 및 테두리 여백
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 36)
            
            // 확장 패널 (아일랜드) - 상단 중앙에 직접 배치
            if windowKind == .workspace {
                VStack(spacing: 8) {
                    IslandPillView(scanner: activityScanner, hover: islandHover)
                        // full-size content의 실제 창 상단 기준. 30pt pill 중심이
                        // 신호등 중심선과 맞고, 아래 패널은 pill 다음에 자연히 열린다.
                        .padding(.top, 6)

                    IslandPanelView(scanner: activityScanner, hover: islandHover)
                }
            }
        }
        // hiddenTitleBar도 SwiftUI 컨테이너에는 기존 타이틀바 safe area를 남긴다.
        // 캔버스 좌표계를 창 프레임 상단까지 확장하고, 신호등과 카드의 간격은
        // 위 HStack의 명시적 36pt inset 하나로만 관리한다.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            WindowBindingView(appState: appState, scanner: activityScanner, hover: islandHover)
                .frame(width: 0, height: 0)
        }
        .environmentObject(appState)
        .focusedSceneObject(appState)
        .preferredColorScheme(preferredScheme)
        .onChange(of: appState.preferredAppearance) {
            // tmux 상태바는 전역 — 마지막으로 토글된 창의 무드를 따른다 (라이트→soft)
            if windowKind == .workspace && appState.preferredAppearance == "light" {
                AppearanceManager.syncTmuxThemeToSoft()
            }
        }
        .sheet(isPresented: $appState.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showAddProjectSheet) {
            AddProjectSheet()
                .environmentObject(appState)
        }
        .onAppear {
            RecentActivityScanner.shared.start()
            WindowRestorer.openRemainingWindowsIfNeeded(openWindow)
        }
    }
}

/// Sheet for creating a new workspace
struct NewWorkspaceSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var path = ""
    @State private var customName = ""
    @Environment(\.dismiss) var dismiss

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Select Folder")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("Folder Path", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true   // 새 프로젝트 폴더를 그 자리에서 만들 수 있게

                        if panel.runModal() == .OK, let url = panel.url {
                            path = url.path
                        }
                    }
                }

                if !path.isEmpty {
                    Text("Name: \(customName.isEmpty ? folderName : customName)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Custom Name (optional)", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    if !path.isEmpty {
                        appState.createWorkspace(
                            rootPath: path,
                            customName: customName.isEmpty ? nil : customName
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(30)
    }
}

/// Sheet for adding a project folder
struct AddProjectSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var path = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Project Folder")
                .font(.headline)

            HStack {
                TextField("Folder Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true

                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    if !path.isEmpty {
                        appState.addProject(path: path)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(30)
    }
}
