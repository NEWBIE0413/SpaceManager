import SwiftUI

/// Main content view with two-pane layout
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 200)
        } detail: {
            TerminalAreaView()
        }
        .sheet(isPresented: $appState.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
        }
        .sheet(isPresented: $appState.showAddProjectSheet) {
            AddProjectSheet()
        }
        .sheet(isPresented: $appState.showModelConfigEditor) {
            ModelConfigEditorSheet()
        }
        .sheet(isPresented: $appState.showSettingsSheet) {
            SettingsSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            appState.showSettingsSheet = true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
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

/// Sheet for editing a model config
struct ModelConfigEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var name = ""
    @State private var newCommand = ""
    @State private var resumeCommand = ""
    @State private var selectedColor: Color = .gray
    @Environment(\.dismiss) var dismiss

    private let colorOptions: [(String, Color)] = [
        ("FF9500", .orange),
        ("34C759", .green),
        ("007AFF", .blue),
        ("AF52DE", .purple),
        ("FF3B30", .red),
        ("FFCC00", .yellow),
        ("00C7BE", .cyan),
        ("8E8E93", .gray),
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text(appState.editingModelConfig == nil ? "Add Model" : "Edit Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Claude", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("New Session Command")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., claude", text: $newCommand)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Resume Command")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., claude --resume", text: $resumeCommand)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    Text("Leave both empty for shell-only mode")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(colorOptions, id: \.0) { hex, color in
                            Circle()
                                .fill(color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(selectedColor == color ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .shadow(color: selectedColor == color ? color.opacity(0.5) : .clear, radius: 4)
                                .onTapGesture {
                                    selectedColor = color
                                }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if appState.editingModelConfig != nil {
                    Button("Delete", role: .destructive) {
                        if let config = appState.editingModelConfig {
                            appState.storage.deleteModelConfig(config)
                        }
                        appState.editingModelConfig = nil
                        dismiss()
                    }
                }

                Button("Save") {
                    saveConfig()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(30)
        .onAppear {
            if let config = appState.editingModelConfig {
                name = config.name
                newCommand = config.newCommand
                resumeCommand = config.resumeCommand
                selectedColor = config.color
            }
        }
    }

    private func saveConfig() {
        let colorHex = colorOptions.first { $0.1 == selectedColor }?.0 ?? "808080"

        if var config = appState.editingModelConfig {
            config.name = name
            config.newCommand = newCommand
            config.resumeCommand = resumeCommand
            config.colorHex = colorHex
            appState.storage.updateModelConfig(config)
        } else {
            let newConfig = ModelConfig(
                name: name,
                newCommand: newCommand,
                resumeCommand: resumeCommand,
                shortcut: "",
                colorHex: colorHex
            )
            appState.storage.addModelConfig(newConfig)
        }
        appState.editingModelConfig = nil
    }
}

/// Settings sheet with model management
struct SettingsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Focus section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Focus")
                            .font(.headline)

                        Text("Choose how agent focus changes in split view.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Agent Focus", selection: $appState.agentFocusMode) {
                            ForEach(AgentFocusMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }

                    // Models section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Models")
                                .font(.headline)
                            Spacer()
                            Button {
                                appState.editingModelConfig = nil
                                appState.showModelConfigEditor = true
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Configure models with their new session and resume commands.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Model list
                        VStack(spacing: 2) {
                            ForEach(appState.storage.modelConfigs) { config in
                                ModelSettingsRow(config: config)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)

                        HStack {
                            Spacer()
                            Button("Reset to Defaults") {
                                appState.storage.resetModelConfigs()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 450)
    }
}

/// Row for a model in settings
struct ModelSettingsRow: View {
    @EnvironmentObject var appState: AppState
    let config: ModelConfig

    var body: some View {
        HStack(spacing: 12) {
            // Shortcut indicator
            Text("[\(config.shortcut)]")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(config.color)
                .frame(width: 30)

            // Color dot
            Circle()
                .fill(config.color)
                .frame(width: 10, height: 10)

            // Name & commands
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    if !config.newCommand.isEmpty {
                        Text("New: \(config.newCommand)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !config.resumeCommand.isEmpty {
                        Text("Resume: \(config.resumeCommand)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if config.newCommand.isEmpty && config.resumeCommand.isEmpty {
                        Text("(shell only)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Edit button
            Button {
                appState.editingModelConfig = config
                appState.showModelConfigEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            // Delete button
            Button {
                appState.storage.deleteModelConfig(config)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
