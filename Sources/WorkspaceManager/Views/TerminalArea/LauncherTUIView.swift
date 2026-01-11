import SwiftUI
import AppKit

/// Launcher state machine
enum LauncherState {
    case selectModel
    case selectMode(ModelConfig)
    case customCommand
}

/// TUI-style launcher view with two-step flow
struct LauncherTUIView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var appState: AppState
    @State private var state: LauncherState = .selectModel
    @State private var selectedIndex: Int = 0
    @State private var customCommand: String = ""

    var models: [ModelConfig] {
        appState.storage.modelConfigs
    }

    var body: some View {
        LauncherKeyboardView(
            state: $state,
            selectedIndex: $selectedIndex,
            customCommand: $customCommand,
            modelCount: models.count,
            onLaunchNew: { launchNew() },
            onLaunchResume: { launchResume() },
            onLaunchCustom: { launchCustom() },
            onSelectModel: { selectModel(at: $0) }
        ) {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.12)

            VStack(spacing: 0) {
                Spacer()

                switch state {
                case .selectModel:
                    modelSelectionView
                case .selectMode(let model):
                    modeSelectionView(for: model)
                case .customCommand:
                    customCommandView
                }

                Spacer()
            }
        }
    }

    // MARK: - Model Selection View

    private var modelSelectionView: some View {
        VStack(spacing: 16) {
            // Header
            Text("SELECT MODEL")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .tracking(2)

            // Model list
            VStack(spacing: 4) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    ModelRow(
                        model: model,
                        isSelected: index == selectedIndex
                    )
                    .onTapGesture {
                        selectedIndex = index
                        selectModel(at: index)
                    }
                }
            }
            .frame(maxWidth: 380)

            Spacer().frame(height: 16)

            // Help
            VStack(spacing: 2) {
                Text("[1-\(min(models.count, 9))] select  •  [↑↓] navigate  •  [Enter] confirm")
                Text("[C] custom command  •  [E] edit models")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Mode Selection View

    private func modeSelectionView(for model: ModelConfig) -> some View {
        VStack(spacing: 16) {
            // Header with model name
            HStack(spacing: 8) {
                Circle()
                    .fill(model.color)
                    .frame(width: 10, height: 10)
                Text(model.name.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            // Mode options
            VStack(spacing: 6) {
                ModeRow(
                    shortcut: "N",
                    title: "New Session",
                    command: model.newCommand,
                    color: .green,
                    isSelected: selectedIndex == 0
                )
                .onTapGesture {
                    selectedIndex = 0
                    launchNew()
                }

                if !model.resumeCommand.isEmpty {
                    ModeRow(
                        shortcut: "R",
                        title: "Resume",
                        command: model.resumeCommand,
                        color: .blue,
                        isSelected: selectedIndex == 1
                    )
                    .onTapGesture {
                        selectedIndex = 1
                        launchResume()
                    }
                }
            }
            .frame(maxWidth: 380)

            Spacer().frame(height: 16)

            // Help
            Text("[N] new  •  [R] resume  •  [Esc] back")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Custom Command View

    private var customCommandView: some View {
        VStack(spacing: 16) {
            Text("CUSTOM COMMAND")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .tracking(2)

            HStack(spacing: 8) {
                Text(">")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)

                TextField("", text: $customCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: 300)
                    .onSubmit {
                        launchCustom()
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)

            Text("[Enter] run  •  [Esc] back")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Actions

    private func selectModel(at index: Int) {
        guard index < models.count else { return }
        let model = models[index]

        // If it's shell (empty commands), launch directly
        if model.newCommand.isEmpty && model.resumeCommand.isEmpty {
            session.launch(command: "")
            return
        }

        // Go to mode selection
        selectedIndex = 0
        state = .selectMode(model)
    }

    private func launchNew() {
        if case .selectMode(let model) = state {
            session.launch(command: model.newCommand)
        }
    }

    private func launchResume() {
        if case .selectMode(let model) = state {
            session.launch(command: model.resumeCommand)
        }
    }

    private func launchCustom() {
        guard !customCommand.isEmpty else { return }
        session.launch(command: customCommand)
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: ModelConfig
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("[\(model.shortcut)]")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(model.color)
                .frame(width: 28)

            Circle()
                .fill(model.color)
                .frame(width: 8, height: 8)

            Text(model.name)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if isSelected {
                Text("◀")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(model.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? model.color.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Mode Row

struct ModeRow: View {
    let shortcut: String
    let title: String
    let command: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("[\(shortcut)]")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))

                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            if isSelected {
                Text("◀")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Keyboard Handler

struct LauncherKeyboardView<Content: View>: NSViewRepresentable {
    @Binding var state: LauncherState
    @Binding var selectedIndex: Int
    @Binding var customCommand: String
    let modelCount: Int
    let onLaunchNew: () -> Void
    let onLaunchResume: () -> Void
    let onLaunchCustom: () -> Void
    let onSelectModel: (Int) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> LauncherNSView {
        let view = LauncherNSView()

        let hostingView = NSHostingView(rootView: AnyView(content()))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let coordinator = context.coordinator
        view.keyHandler = { event in
            coordinator.handleKeyDown(event)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            view.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: LauncherNSView, context: Context) {
        context.coordinator.update(
            state: $state,
            selectedIndex: $selectedIndex,
            customCommand: $customCommand,
            modelCount: modelCount,
            onLaunchNew: onLaunchNew,
            onLaunchResume: onLaunchResume,
            onLaunchCustom: onLaunchCustom,
            onSelectModel: onSelectModel
        )

        // Update content
        if let hostingView = nsView.subviews.first as? NSHostingView<AnyView> {
            hostingView.rootView = AnyView(content())
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var state: Binding<LauncherState>?
        var selectedIndex: Binding<Int>?
        var customCommand: Binding<String>?
        var modelCount: Int = 0
        var onLaunchNew: (() -> Void)?
        var onLaunchResume: (() -> Void)?
        var onLaunchCustom: (() -> Void)?
        var onSelectModel: ((Int) -> Void)?

        func update(
            state: Binding<LauncherState>,
            selectedIndex: Binding<Int>,
            customCommand: Binding<String>,
            modelCount: Int,
            onLaunchNew: @escaping () -> Void,
            onLaunchResume: @escaping () -> Void,
            onLaunchCustom: @escaping () -> Void,
            onSelectModel: @escaping (Int) -> Void
        ) {
            self.state = state
            self.selectedIndex = selectedIndex
            self.customCommand = customCommand
            self.modelCount = modelCount
            self.onLaunchNew = onLaunchNew
            self.onLaunchResume = onLaunchResume
            self.onLaunchCustom = onLaunchCustom
            self.onSelectModel = onSelectModel
        }

        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let state = state,
                  let selectedIndex = selectedIndex else { return false }

            let keyCode = event.keyCode
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch state.wrappedValue {
            case .selectModel:
                return handleModelSelection(keyCode: keyCode, chars: chars, selectedIndex: selectedIndex)

            case .selectMode:
                return handleModeSelection(keyCode: keyCode, chars: chars, state: state, selectedIndex: selectedIndex)

            case .customCommand:
                return handleCustomCommand(keyCode: keyCode, state: state)
            }
        }

        private func handleModelSelection(keyCode: UInt16, chars: String, selectedIndex: Binding<Int>) -> Bool {
            switch keyCode {
            case 126: // Up
                if selectedIndex.wrappedValue > 0 {
                    selectedIndex.wrappedValue -= 1
                }
                return true

            case 125: // Down
                if selectedIndex.wrappedValue < modelCount - 1 {
                    selectedIndex.wrappedValue += 1
                }
                return true

            case 36: // Enter
                onSelectModel?(selectedIndex.wrappedValue)
                return true

            default:
                // Number keys
                if let num = Int(chars), num >= 1, num <= modelCount {
                    selectedIndex.wrappedValue = num - 1
                    onSelectModel?(num - 1)
                    return true
                }

                // C for custom
                if chars == "c" {
                    state?.wrappedValue = .customCommand
                    return true
                }

                // E for edit (open settings)
                if chars == "e" {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                    return true
                }
            }

            return false
        }

        private func handleModeSelection(keyCode: UInt16, chars: String, state: Binding<LauncherState>, selectedIndex: Binding<Int>) -> Bool {
            switch keyCode {
            case 126: // Up
                if selectedIndex.wrappedValue > 0 {
                    selectedIndex.wrappedValue -= 1
                }
                return true

            case 125: // Down
                if selectedIndex.wrappedValue < 1 {
                    selectedIndex.wrappedValue += 1
                }
                return true

            case 36: // Enter
                if selectedIndex.wrappedValue == 0 {
                    onLaunchNew?()
                } else {
                    onLaunchResume?()
                }
                return true

            case 53: // Escape - go back
                selectedIndex.wrappedValue = 0
                state.wrappedValue = .selectModel
                return true

            default:
                if chars == "n" {
                    onLaunchNew?()
                    return true
                }
                if chars == "r" {
                    onLaunchResume?()
                    return true
                }
            }

            return false
        }

        private func handleCustomCommand(keyCode: UInt16, state: Binding<LauncherState>) -> Bool {
            if keyCode == 53 { // Escape
                customCommand?.wrappedValue = ""
                state.wrappedValue = .selectModel
                return true
            }
            // Let text field handle other keys
            return false
        }
    }
}

class LauncherNSView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }
}

// Notification for opening settings
extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}
