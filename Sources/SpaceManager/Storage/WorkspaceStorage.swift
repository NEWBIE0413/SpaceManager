import Foundation

/// Handles persistence of workspaces to disk
class WorkspaceStorage: ObservableObject {
    static let shared = WorkspaceStorage()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    @Published var workspaces: [Workspace] = []

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

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureStorageDirectoryExists()
        loadWorkspaces()
        // models.json·agent-states.json은 더 이상 로드하지 않는다 (파일은 남겨둠 — 롤백 안전)
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
}
