import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // TmuxBootstrap.isTmuxAvailable synchronously spawns a login shell on first
        // access. Warm it up off the main thread so AppState/view init doesn't block
        // the UI on that first evaluation (static let is once-semantics/thread-safe,
        // so later on-thread access just reads the cached value).
        DispatchQueue.global(qos: .utility).async {
            _ = TmuxBootstrap.isTmuxAvailable
        }
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
}

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["SM_SPIKE"] == "1" {
                TerminalSpikeView()
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                ContentView()
                    .environmentObject(appState)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    appState.showNewWorkspaceSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Terminal Tab") {
                    appState.addShellTab()
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandMenu("Tabs") {
                Button("Previous Tab") {
                    appState.selectPreviousSession()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Next Tab") {
                    appState.selectNextSession()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
        }
    }
}
