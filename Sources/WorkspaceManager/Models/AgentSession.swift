import Foundation
import SwiftUI
import SwiftTerm
import AppKit

/// Notification when a session launches
extension Notification.Name {
    static let sessionDidLaunch = Notification.Name("sessionDidLaunch")
}

/// Represents a running agent/terminal session
/// Owns the terminal process to ensure it persists across view updates
class AgentSession: Identifiable, ObservableObject, Equatable {
    let id: UUID
    @Published var name: String
    @Published var workingDirectory: String
    @Published var isRunning: Bool = false
    @Published var hasLaunchedCommand: Bool = false
    @Published var launchCommand: String = ""

    // Terminal view - owned by the session, not the SwiftUI view
    private(set) var terminalView: LocalProcessTerminalView?
    private var terminalStarted = false

    init(id: UUID = UUID(), name: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
    }

    func launch(command: String) {
        self.launchCommand = command
        self.hasLaunchedCommand = true
        self.isRunning = true

        // Notify that this session launched so views can update
        NotificationCenter.default.post(name: .sessionDidLaunch, object: self.id)
    }

    /// Get or create the terminal view for this session
    func getOrCreateTerminal() -> LocalProcessTerminalView {
        if let existing = terminalView {
            return existing
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)

        self.terminalView = terminal
        return terminal
    }

    /// Start the terminal process if not already started
    func startTerminalIfNeeded() {
        guard !terminalStarted, let terminal = terminalView else { return }
        terminalStarted = true

        // Get user's shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = "-" + (shell as NSString).lastPathComponent

        // Change to working directory
        if FileManager.default.fileExists(atPath: workingDirectory) {
            FileManager.default.changeCurrentDirectoryPath(workingDirectory)
        } else {
            FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())
        }

        // Start shell
        terminal.startProcess(executable: shell, execName: shellName)

        // Run launch command if set
        if !launchCommand.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.terminalView?.send(txt: (self?.launchCommand ?? "") + "\n")
            }
        }
    }

    /// Focus this terminal
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.window?.makeFirstResponder(self?.terminalView)
        }
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
    }
}
