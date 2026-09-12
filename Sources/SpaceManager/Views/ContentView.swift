import SwiftUI
import AppKit

/// Main content view with two-pane layout.
/// 창마다 하나씩 생성된다 — AppState가 여기 살아야 창별 독립 선택이 가능하다.
struct ContentView: View {
    private let windowKind: WindowKind
    @Binding private var sceneWindowStateId: UUID?
    @StateObject private var appState: AppState
    // The island and sidebar observe their own data. Activity updates must not
    // invalidate the entire window and refocus/re-layout its terminal.
    private let activityScanner = RecentActivityScanner.shared
    @StateObject private var islandHover = IslandHoverState()
    @StateObject private var terminalLayout = TerminalLayoutTransition()
    @SceneStorage("workspaceSidebarCompact") private var isSidebarCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    init(windowKind: WindowKind = .workspace, windowStateId: Binding<UUID?> = .constant(nil)) {
        self.windowKind = windowKind
        _sceneWindowStateId = windowStateId
        _appState = StateObject(wrappedValue: AppState(
            windowKind: windowKind,
            requestedWindowStateId: windowStateId.wrappedValue
        ))
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

    private var windowTitle: String {
        if windowKind == .quick {
            return appState.selectedSession?.name ?? "Hermes"
        }
        return appState.selectedWorkspace?.name ?? "SpaceManager"
    }

    private var sidebarBinding: Binding<Bool> {
        Binding(get: { isSidebarCompact }, set: { compact in
            guard compact != isSidebarCompact else { return }
            // Suspend the native viewport before SwiftUI starts laying out either
            // panel. Interrupted animations may complete after the next toggle.
            let transition = terminalLayout.begin()
            withAnimation(reduceMotion ? nil : Sidebar.collapseAnimation, completionCriteria: .removed) {
                isSidebarCompact = compact
            } completion: {
                terminalLayout.finish(transition)
            }
        })
    }

    var body: some View {
        ZStack(alignment: .top) {
            WorkspaceCanvasSurface(windowKind: windowKind, isDark: isDarkNow)
                .ignoresSafeArea()
            
            HStack(alignment: .top, spacing: windowKind == .workspace ? 10 : 12) {
                Group {
                    if windowKind == .quick {
                        QuickSidebarView()
                    } else {
                        SidebarView(isCompact: sidebarBinding)
                    }
                }
                    .frame(width: windowKind == .workspace && isSidebarCompact ? Sidebar.compactWidth : Sidebar.expandedWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                
                TerminalAreaView()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if windowKind == .workspace {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        }
                    }
                    .background {
                        // Shadow the card shape, not WebKit's changing pixels.
                        // This avoids offscreen compositing of the terminal on
                        // every frame of the shared panel animation.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: GlassSurfacePolicy.terminalCardColor(for: windowKind)))
                            .shadow(color: Color.black.opacity(isDarkNow ? 0.3 : 0.1), radius: 8, x: 0, y: 4)
                    }
            }
            .padding(windowKind == .workspace ? 8 : 12)

            // A separate top layer stays above the native terminal during layout
            // changes, centered on the whole window without reserving height.
            if windowKind == .workspace {
                FloatingActivityIsland(scanner: activityScanner, hover: islandHover, appState: appState)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .zIndex(1)
            }
        }
        // Extend both panels into the titlebar; only the narrow outer frame remains.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            WindowBindingView(
                appState: appState,
                scanner: activityScanner,
                hover: islandHover,
                title: windowTitle
            )
                .frame(width: 0, height: 0)
        }
        .environmentObject(appState)
        .environmentObject(terminalLayout)
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
            if appState.shouldCloseOnAppearance {
                dismiss()
                return
            }
            // WindowGroup scene value는 macOS가 창별로 복원한다. 최초/레거시 nil scene에는
            // 실제 claim 결과를 기록해 다음 실행부터 같은 WindowState.id를 돌려받는다.
            if sceneWindowStateId == nil {
                sceneWindowStateId = appState.windowStateId
            }
            if windowKind == .workspace {
                RecentActivityScanner.shared.start(owner: appState.windowStateId)
            }
            WindowRestorer.openRemainingWindowsIfNeeded(openWindow)
            WindowOpener.register(openWindow)   // CLI(window.new / quick.new)가 창을 열 수 있게
        }
        .onDisappear {
            if windowKind == .workspace, !appState.shouldCloseOnAppearance {
                RecentActivityScanner.shared.stop(owner: appState.windowStateId)
            }
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
