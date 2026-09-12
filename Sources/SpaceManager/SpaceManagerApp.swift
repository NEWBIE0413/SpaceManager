import SwiftUI
import AppKit

enum AppTermination {
    static var isTerminating = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `sm` CLI 제어 소켓. 실패해도 앱은 정상 동작한다 — CLI만 못 붙는다.
        let server = ControlServer(path: ControlCommands.socketPath) { request, respond in
            ControlCommands.handle(request, completion: respond)
        }
        do { try server.start(); controlServer = server } catch {
            NSLog("control server unavailable: \(error)")
        }
        // 라이트/다크는 창별(AppState.preferredAppearance → NSWindow.appearance) —
        // 전역 NSApp.appearance는 건드리지 않는다
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controlServer?.stop()
        WorkspaceWindowRegistry.shared.persistWindowPresentations()
        // 종료 시 AppState.deinit이 창 상태를 지우지 않도록 표시
        AppTermination.isTerminating = true
        return .terminateNow
    }
}

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main", for: UUID.self) { $windowStateId in
            if ProcessInfo.processInfo.environment["SM_SPIKE"] == "1" {
                TerminalSpikeView()
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                ContentView(windowStateId: $windowStateId)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands()
        }

        WindowGroup(id: "quick", for: UUID.self) { $windowStateId in
            ContentView(windowKind: .quick, windowStateId: $windowStateId)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// 메뉴 커맨드 — FocusedObject로 "활성 창"의 AppState에 바인딩된다
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Quick Window") {
                openWindow(id: "quick", value: UUID())
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("New Workspace") {
                appState?.showNewWorkspaceSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appState == nil || appState?.windowKind == .quick)

            Button(appState?.windowKind == .quick ? "New Quick Conversation" : "New Terminal Tab") {
                appState?.addDefaultTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState == nil)

            Button("New tmux Tab") {
                appState?.addTmuxTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(appState == nil || appState?.windowKind == .quick || !TmuxBootstrap.isTmuxAvailable)
        }

        CommandMenu("Tabs") {
            Button("Previous Tab") {
                appState?.selectPreviousSession()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(appState == nil)

            Button("Next Tab") {
                appState?.selectNextSession()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(appState == nil)
        }
    }
}

    /// 앱 시작 시 아직 macOS scene restoration이 만들지 않은 상태만 정확한 ID로 연다.
enum WindowRestorer {
    private static var didRun = false

    @MainActor
    static func openRemainingWindowsIfNeeded(_ openWindow: OpenWindowAction) {
        guard !didRun else { return }
        didRun = true
        // 시스템 상태 복원이 창을 이미 띄웠을 수 있으므로 잠시 뒤 부족분 계산
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let storage = WorkspaceStorage.shared
            for kind in WindowKind.allCases {
                for state in storage.unclaimedWindowStates(for: kind) {
                    openWindow(id: kind.sceneID, value: state.id)
                }
            }
        }
    }
}
