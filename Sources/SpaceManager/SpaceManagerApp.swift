import SwiftUI
import AppKit

enum AppTermination {
    static var isTerminating = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        // 종료 시 AppState.deinit이 창 상태를 지우지 않도록 표시
        AppTermination.isTerminating = true
        return .terminateNow
    }
}

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            if ProcessInfo.processInfo.environment["SM_SPIKE"] == "1" {
                TerminalSpikeView()
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                ContentView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands()
        }
    }
}

/// 메뉴 커맨드 — FocusedObject로 "활성 창"의 AppState에 바인딩된다
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("New Workspace") {
                appState?.showNewWorkspaceSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("New Terminal Tab") {
                appState?.addShellTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState == nil)

            Button("New tmux Tab") {
                appState?.addTmuxTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(appState == nil || !TmuxBootstrap.isTmuxAvailable)
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

/// 앱 시작 시 저장된 창 수만큼 창을 복원한다.
/// 우리 북키핑(claimedCount) 기준으로 부족분만 열어 시스템 복원과의 중복을 방지.
enum WindowRestorer {
    private static var didRun = false

    @MainActor
    static func openRemainingWindowsIfNeeded(_ openWindow: OpenWindowAction) {
        guard !didRun else { return }
        didRun = true
        // 시스템 상태 복원이 창을 이미 띄웠을 수 있으므로 잠시 뒤 부족분 계산
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let storage = WorkspaceStorage.shared
            let missing = storage.windowStates.count - storage.claimedCount
            guard missing > 0 else { return }
            for _ in 0..<missing {
                openWindow(id: "main")
            }
        }
    }
}
