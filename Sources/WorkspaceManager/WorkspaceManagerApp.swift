import SwiftUI

@main
struct WorkspaceManagerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    appState.showNewWorkspaceSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Agent Tab") {
                    appState.addAgentSession()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}
