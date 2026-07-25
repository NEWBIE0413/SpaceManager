import Foundation

/// Handles persistence of workspaces to disk
class WorkspaceStorage: ObservableObject {
    static let shared = WorkspaceStorage()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 레거시 마이그레이션 입력 전용 (읽기 전용) — 워크스페이스의 실소유는 창별 WindowState.
    @Published var workspaces: [Workspace] = []
    @Published var windowStates: [WindowState] = []
    private var claimedWindowStateIds: Set<UUID> = []
    private var claimedWindowKinds: [UUID: WindowKind] = [:]

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

    private var windowStatesFile: URL {
        storageDirectory.appendingPathComponent("window-states.json")
    }

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureStorageDirectoryExists()
        loadWorkspaces()
        loadWindowStates()
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

    // MARK: - Window State Persistence

    func loadWindowStates() {
        guard fileManager.fileExists(atPath: windowStatesFile.path) else {
            windowStates = []
            return
        }
        do {
            let data = try Data(contentsOf: windowStatesFile)
            windowStates = try decoder.decode([WindowState].self, from: data)
        } catch {
            print("Error loading window states: \(error)")
            windowStates = []
        }
    }

    func saveWindowStates() {
        do {
            let data = try encoder.encode(windowStates)
            try data.write(to: windowStatesFile, options: .atomic)
        } catch {
            print("Error saving window states: \(error)")
        }
    }

    /// 아직 어떤 창도 가져가지 않은 저장 상태를 하나 claim (인메모리 — 파일은 불변)
    func claimNextWindowState(kind: WindowKind) -> WindowState? {
        guard let state = windowStates.first(where: {
            $0.resolvedKind == kind && !claimedWindowStateIds.contains($0.id)
        }) else {
            return nil
        }
        claimedWindowStateIds.insert(state.id)
        claimedWindowKinds[state.id] = kind
        return state
    }

    func registerClaimed(_ id: UUID, kind: WindowKind) {
        claimedWindowStateIds.insert(id)
        claimedWindowKinds[id] = kind
    }

    var claimedCount: Int { claimedWindowStateIds.count }

    func claimedCount(for kind: WindowKind) -> Int {
        claimedWindowKinds.values.filter { $0 == kind }.count
    }

    func savedCount(for kind: WindowKind) -> Int {
        windowStates.filter { $0.resolvedKind == kind }.count
    }

    func updateWindowState(_ state: WindowState) {
        if let index = windowStates.firstIndex(where: { $0.id == state.id }) {
            windowStates[index] = state
        } else {
            windowStates.append(state)
        }
        saveWindowStates()
    }

    func removeWindowState(id: UUID) {
        claimedWindowStateIds.remove(id)
        claimedWindowKinds[id] = nil
        windowStates.removeAll { $0.id == id }
        saveWindowStates()
    }
}
