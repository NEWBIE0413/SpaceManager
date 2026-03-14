import Foundation

/// Handles persistence of workspaces to disk
class WorkspaceStorage: ObservableObject {
    static let shared = WorkspaceStorage()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    @Published var workspaces: [Workspace] = []
    @Published var modelConfigs: [ModelConfig] = []
    @Published var agentStates: [WorkspaceAgentState] = []

    /// Base directory for storage
    private var storageDirectory: URL {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".space-manager")
    }

    /// Legacy directory for migration
    private var legacyStorageDirectory: URL {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".workspace-manager")
    }

    /// Path to workspaces file
    private var workspacesFile: URL {
        storageDirectory.appendingPathComponent("workspaces.json")
    }

    /// Path to model configs file
    private var modelConfigsFile: URL {
        storageDirectory.appendingPathComponent("models.json")
    }

    /// Path to agent state file
    private var agentStatesFile: URL {
        storageDirectory.appendingPathComponent("agent-states.json")
    }

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureStorageDirectoryExists()
        loadWorkspaces()
        loadModelConfigs()
        loadAgentStates()
    }

    private func ensureStorageDirectoryExists() {
        do {
            if fileManager.fileExists(atPath: legacyStorageDirectory.path),
               !fileManager.fileExists(atPath: storageDirectory.path) {
                try fileManager.moveItem(at: legacyStorageDirectory, to: storageDirectory)
            }
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        } catch {
            print("Warning: Could not create storage directory: \(error)")
        }
    }

    /// Load all workspaces from disk
    func loadWorkspaces() {
        guard fileManager.fileExists(atPath: workspacesFile.path) else {
            workspaces = []
            return
        }

        do {
            let data = try Data(contentsOf: workspacesFile)
            workspaces = try decoder.decode([Workspace].self, from: data)
        } catch {
            print("Error loading workspaces: \(error)")
            workspaces = []
        }
    }

    /// Save all workspaces to disk
    func saveWorkspaces() {
        do {
            let data = try encoder.encode(workspaces)
            try data.write(to: workspacesFile)
        } catch {
            print("Error saving workspaces: \(error)")
        }
    }

    /// Add a new workspace
    func addWorkspace(_ workspace: Workspace) {
        workspaces.append(workspace)
        saveWorkspaces()
    }

    /// Update an existing workspace
    func updateWorkspace(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
            saveWorkspaces()
        }
    }

    /// Delete a workspace
    func deleteWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        saveWorkspaces()
    }

    /// Move a workspace to a new position
    func moveWorkspace(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else { return }
        guard sourceIndex >= 0, sourceIndex < workspaces.count else { return }
        guard destinationIndex >= 0, destinationIndex <= workspaces.count else { return }

        var updated = workspaces
        updated.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        workspaces = updated
        saveWorkspaces()
    }

    /// Get workspace by ID
    func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    // MARK: - Model Configs

    /// Load model configs from disk
    func loadModelConfigs() {
        guard fileManager.fileExists(atPath: modelConfigsFile.path) else {
            // Use defaults if no saved configs
            modelConfigs = ModelConfig.defaults
            saveModelConfigs()
            return
        }

        do {
            let data = try Data(contentsOf: modelConfigsFile)
            modelConfigs = try decoder.decode([ModelConfig].self, from: data)
        } catch {
            print("Error loading model configs: \(error)")
            modelConfigs = ModelConfig.defaults
        }
    }

    /// Save model configs to disk
    func saveModelConfigs() {
        do {
            let data = try encoder.encode(modelConfigs)
            try data.write(to: modelConfigsFile)
        } catch {
            print("Error saving model configs: \(error)")
        }
    }

    /// Add a new model config
    func addModelConfig(_ config: ModelConfig) {
        modelConfigs.append(config)
        reassignShortcuts()
        saveModelConfigs()
    }

    /// Update an existing model config
    func updateModelConfig(_ config: ModelConfig) {
        if let index = modelConfigs.firstIndex(where: { $0.id == config.id }) {
            modelConfigs[index] = config
            saveModelConfigs()
        }
    }

    /// Delete a model config
    func deleteModelConfig(_ config: ModelConfig) {
        modelConfigs.removeAll { $0.id == config.id }
        reassignShortcuts()
        saveModelConfigs()
    }

    /// Move model config (reorder)
    func moveModelConfig(from source: IndexSet, to destination: Int) {
        modelConfigs.move(fromOffsets: source, toOffset: destination)
        reassignShortcuts()
        saveModelConfigs()
    }

    /// Reassign shortcuts based on position (1-9, then 0)
    private func reassignShortcuts() {
        for (index, _) in modelConfigs.enumerated() {
            let shortcut: String
            if index < 9 {
                shortcut = "\(index + 1)"
            } else if index == 9 {
                shortcut = "0"
            } else {
                shortcut = ""  // No shortcut for items beyond 10
            }
            modelConfigs[index].shortcut = shortcut
        }
    }

    /// Reset to default configs
    func resetModelConfigs() {
        modelConfigs = ModelConfig.defaults
        saveModelConfigs()
    }

    // MARK: - Agent States

    /// Load agent states from disk
    func loadAgentStates() {
        guard fileManager.fileExists(atPath: agentStatesFile.path) else {
            agentStates = []
            return
        }

        do {
            let data = try Data(contentsOf: agentStatesFile)
            agentStates = try decoder.decode([WorkspaceAgentState].self, from: data)
        } catch {
            print("Error loading agent states: \(error)")
            agentStates = []
        }
    }

    /// Save agent states to disk
    func saveAgentStates() {
        do {
            let data = try encoder.encode(agentStates)
            try data.write(to: agentStatesFile)
        } catch {
            print("Error saving agent states: \(error)")
        }
    }

    func updateAgentState(_ state: WorkspaceAgentState) {
        if let index = agentStates.firstIndex(where: { $0.workspaceId == state.workspaceId }) {
            agentStates[index] = state
        } else {
            agentStates.append(state)
        }
        saveAgentStates()
    }

    func removeAgentState(for workspaceId: UUID) {
        agentStates.removeAll { $0.workspaceId == workspaceId }
        saveAgentStates()
    }
}
