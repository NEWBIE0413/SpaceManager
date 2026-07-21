import SwiftUI
import AppKit

/// Main content view with two-pane layout.
/// 창마다 하나씩 생성된다 — AppState가 여기 살아야 창별 독립 선택이 가능하다.
struct ContentView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var activityScanner = RecentActivityScanner.shared
    @StateObject private var islandHover = IslandHoverState()
    @Environment(\.openWindow) private var openWindow

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
        switch appState.preferredAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 200)
        } detail: {
            TerminalAreaView()
        }
        // 확장 패널은 창 전체 기준 상단 중앙 — 타이틀바의 필에서 내려오는 노치 연출
        .overlay(alignment: .top) {
            IslandPanelView(scanner: activityScanner, hover: islandHover)
                .padding(.top, 4)
        }
        .environmentObject(appState)
        .focusedSceneObject(appState)
        .preferredColorScheme(preferredScheme)
        .onChange(of: appState.preferredAppearance) {
            // tmux 상태바는 전역 — 마지막으로 토글된 창의 무드를 따른다 (라이트→soft)
            if appState.preferredAppearance == "light" {
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
        .navigationTitle(appState.selectedWorkspace?.name ?? "SpaceManager")
        .toolbar {
            // macOS 26+ 툴바는 커스텀 아이템 뒤에 glass 캡슐을 자동으로 깔아준다 —
            // 검은 아일랜드 필이 흰 캡슐 안에 갇히므로 공유 배경을 숨긴다
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    IslandPillView(scanner: activityScanner, hover: islandHover)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    themeToggleButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    IslandPillView(scanner: activityScanner, hover: islandHover)
                }
                ToolbarItem(placement: .primaryAction) {
                    themeToggleButton
                }
            }
        }
        .onAppear {
            RecentActivityScanner.shared.start()
            WindowRestorer.openRemainingWindowsIfNeeded(openWindow)
        }
    }

    private var themeToggleButton: some View {
        Button {
            appState.setAppearance(isDarkNow ? "light" : "dark")
        } label: {
            Image(systemName: isDarkNow ? "sun.max" : "moon")
        }
        .buttonStyle(.plain)
        .help(isDarkNow ? "라이트 모드로 전환" : "다크 모드로 전환")
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
