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
    @Published var lastModelId: UUID?
    @Published var lastModelName: String?
    @Published var lastLaunchKind: AgentLaunchKind?
    @Published var lastLaunchCommand: String?
    @Published var sessionTitle: String?

    var stateDidChange: (() -> Void)?

    // Terminal view - owned by the session, not the SwiftUI view
    private(set) var terminalView: ManagedTerminalView?
    private var terminalStarted = false

    init(id: UUID = UUID(), name: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
    }

    func launch(command: String, modelId: UUID? = nil, modelName: String? = nil, kind: AgentLaunchKind = .custom) {
        self.launchCommand = command
        self.hasLaunchedCommand = true
        self.isRunning = true
        self.lastModelId = modelId
        self.lastModelName = modelName
        self.lastLaunchKind = kind
        self.lastLaunchCommand = command
        stateDidChange?()
    }

    var displayName: String {
        if let lastModelName,
           !lastModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastModelName
        }

        if let lastLaunchKind, lastLaunchKind == .shell {
            return "Shell"
        }

        if let lastLaunchCommand,
           !lastLaunchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return commandDisplayName(lastLaunchCommand)
        }

        return name
    }

    private func commandDisplayName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        let tokens = trimmed.split { $0 == " " || $0 == "\t" }
        let commandToken = tokens.first { !$0.contains("=") } ?? tokens.first
        guard let token = commandToken else { return name }
        let tokenString = String(token)
        let base = (tokenString as NSString).lastPathComponent
        return base.isEmpty ? tokenString : base
    }

    /// Get or create the terminal view for this session
    func getOrCreateTerminal() -> ManagedTerminalView {
        if let existing = terminalView {
            return existing
        }

        let terminal = ManagedTerminalView(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.sessionId = id

        // Prefer CJK-friendly monospace fonts to reduce wide-character gaps.
        let fontSize: CGFloat = 13
        let fontCandidates = [
            "D2Coding",
            "NanumGothicCoding",
            "Noto Sans Mono CJK KR",
            "SF Mono",
            "Menlo"
        ]
        terminal.font = fontCandidates
            .compactMap { NSFont(name: $0, size: fontSize) }
            .first
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Use system colors that adapt to light/dark mode
        terminal.nativeBackgroundColor = NSColor.textBackgroundColor
        terminal.nativeForegroundColor = NSColor.textColor
        terminal.caretColor = NSColor.textBackgroundColor
        terminal.setCursorStyle(.steadyBar)
        terminal.terminal.getTerminal().options.alternateBufferEnabled = false
        terminal.terminal.processDelegate = self

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            // cd to working directory
            self.terminalView?.send(txt: "cd \"\(startDir)\" && clear\n")

            // Run launch command if set
            if !self.launchCommand.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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

extension AgentSession {
    convenience init(snapshot: AgentSessionSnapshot) {
        self.init(id: snapshot.id, name: snapshot.name, workingDirectory: snapshot.workingDirectory)
        self.lastModelId = snapshot.lastModelId
        self.lastModelName = snapshot.lastModelName
        self.lastLaunchKind = snapshot.lastLaunchKind
        self.lastLaunchCommand = snapshot.lastLaunchCommand
        self.sessionTitle = snapshot.sessionTitle
        self.hasLaunchedCommand = false
        self.isRunning = false
        self.launchCommand = ""
    }

    func snapshot() -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id,
            name: name,
            workingDirectory: workingDirectory,
            lastModelId: lastModelId,
            lastModelName: lastModelName,
            lastLaunchKind: lastLaunchKind,
            lastLaunchCommand: lastLaunchCommand,
            sessionTitle: sessionTitle
        )
    }
}

extension AgentSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? nil : trimmed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sessionTitle != newTitle {
                self.sessionTitle = newTitle
            }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }
}

/// Container view that manages focus for the terminal.
/// Uses composition since LocalProcessTerminalView methods can't be overridden.
final class ManagedTerminalView: NSView {
    let terminal: FixedCursorTerminalView
    var sessionId: UUID?
    private var selectionActive = false
    private var hoverFocusEnabled = false
    private var hoverTrackingArea: NSTrackingArea?
    private var keyMonitor: Any?

    override init(frame: NSRect) {
        terminal = FixedCursorTerminalView(frame: frame)
        super.init(frame: frame)
        setupTerminal()
    }

    required init?(coder: NSCoder) {
        terminal = FixedCursorTerminalView(frame: .zero)
        super.init(coder: coder)
        setupTerminal()
    }

    private func setupTerminal() {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.onMouseDownAction = { [weak self] in
            self?.notifySelection()
            if let terminal = self?.terminal {
                self?.window?.makeFirstResponder(terminal)
            }
        }
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

    var caretColor: NSColor {
        get { terminal.caretColor }
        set { terminal.caretColor = newValue }
    }

    func setCursorStyle(_ style: CursorStyle) {
        terminal.preferredCursorStyle = style
        terminal.applyCursorPreferences()
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

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(terminal)
        return true
    }

    override func keyDown(with event: NSEvent) {
        terminal.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        terminal.performKeyEquivalent(with: event)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        terminal.validateUserInterfaceItem(item)
    }

    @objc func copy(_ sender: Any?) {
        terminal.copy(sender ?? self)
    }

    @objc func paste(_ sender: Any?) {
        terminal.paste(sender ?? self)
    }

    override func selectAll(_ sender: Any?) {
        terminal.selectAll(sender)
    }

    func setSelectionActive(_ active: Bool) {
        guard selectionActive != active else { return }
        selectionActive = active
        updateKeyMonitor()
    }

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

    private func updateKeyMonitor() {
        if selectionActive {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    guard self.selectionActive, event.window === self.window else { return event }
                    guard self.window?.isKeyWindow == true else { return event }
                    if self.window?.firstResponder is NSTextView {
                        return event
                    }

                    if self.window?.firstResponder !== self.terminal {
                        self.window?.makeFirstResponder(self.terminal)
                    }
                    return event
                }
            }
        } else if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}

final class FixedCursorTerminalView: LocalProcessTerminalView {
    var preferredCursorStyle: CursorStyle = .steadyBar
    var preferredCursorColor: NSColor = NSColor.textBackgroundColor
    var onMouseDownAction: (() -> Void)?

    func applyCursorPreferences() {
        caretColor = preferredCursorColor
        terminal.setCursorStyle(preferredCursorStyle)
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: preferredCursorStyle)
        caretColor = preferredCursorColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyCursorPreferences()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDownAction?()
        super.mouseDown(with: event)
    }
}
