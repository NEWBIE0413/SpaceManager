import Foundation
import SwiftUI
import SwiftTerm
import AppKit

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
    private(set) var terminalView: ManagedTerminalView?
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
    }

    /// Get or create the terminal view for this session
    func getOrCreateTerminal() -> ManagedTerminalView {
        if let existing = terminalView {
            return existing
        }

        let terminal = ManagedTerminalView(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.sessionId = id

        // Use Menlo font which handles CJK/Korean characters better
        // Fall back to system monospaced if Menlo is not available
        let fontSize: CGFloat = 13
        if let menlo = NSFont(name: "Menlo", size: fontSize) {
            terminal.font = menlo
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

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

        // Determine working directory
        let startDir: String
        if FileManager.default.fileExists(atPath: workingDirectory) {
            startDir = workingDirectory
        } else {
            startDir = NSHomeDirectory()
        }

        // Start shell
        terminal.startProcess(executable: shell, execName: shellName)

        // Change to working directory first, then run launch command
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // cd to working directory
            self.terminalView?.send(txt: "cd \"\(startDir)\" && clear\n")

            // Run launch command if set
            if !self.launchCommand.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.terminalView?.send(txt: self.launchCommand + "\n")
                }
            }
        }
    }

    /// Focus this terminal
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.requestFocus()
        }
    }

    /// Clean up terminal resources
    func cleanup() {
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
    }
}

/// Container view that manages focus for the terminal.
/// Uses composition since LocalProcessTerminalView methods can't be overridden.
final class ManagedTerminalView: NSView {
    let terminal: LocalProcessTerminalView
    var sessionId: UUID?
    private var hoverFocusEnabled = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        terminal = LocalProcessTerminalView(frame: frame)
        super.init(frame: frame)
        setupTerminal()
    }

    required init?(coder: NSCoder) {
        terminal = LocalProcessTerminalView(frame: .zero)
        super.init(coder: coder)
        setupTerminal()
    }

    private func setupTerminal() {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    // Forward terminal properties
    var font: NSFont? {
        get { terminal.font }
        set { if let font = newValue { terminal.font = font } }
    }

    var nativeBackgroundColor: NSColor {
        get { terminal.nativeBackgroundColor }
        set { terminal.nativeBackgroundColor = newValue }
    }

    var nativeForegroundColor: NSColor {
        get { terminal.nativeForegroundColor }
        set { terminal.nativeForegroundColor = newValue }
    }

    func startProcess(executable: String, execName: String) {
        terminal.startProcess(executable: executable, execName: execName)
    }

    func send(txt: String) {
        terminal.send(txt: txt)
    }

    func requestFocus() {
        window?.makeFirstResponder(terminal)
    }

    override var acceptsFirstResponder: Bool { false }

    func setHoverFocusEnabled(_ enabled: Bool) {
        guard hoverFocusEnabled != enabled else { return }
        hoverFocusEnabled = enabled
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea = hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        if hoverFocusEnabled {
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
            let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        if hoverFocusEnabled {
            notifySelection()
            window?.makeFirstResponder(terminal)
        }
        super.mouseEntered(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        notifySelection()
        window?.makeFirstResponder(terminal)
        super.mouseDown(with: event)
    }

    private func notifySelection() {
        guard let sessionId = sessionId else { return }
        NotificationCenter.default.post(
            name: .agentSelectionRequested,
            object: nil,
            userInfo: ["id": sessionId]
        )
    }
}
