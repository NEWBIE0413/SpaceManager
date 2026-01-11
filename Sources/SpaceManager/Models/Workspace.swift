import Foundation

/// Represents a single project (folder) in the workspace
struct Project: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var path: String
    var name: String

    init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// Check if the project path exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Get the URL for this project
    var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Represents a workspace containing multiple projects
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var rootPath: String              // Primary folder path
    var customName: String?           // Optional custom name (if renamed)
    var additionalProjects: [Project] // Additional folders beyond root
    var createdAt: Date
    var updatedAt: Date

    /// Display name (custom name or folder name)
    var name: String {
        customName ?? URL(fileURLWithPath: rootPath).lastPathComponent
    }

    /// All projects including root
    var projects: [Project] {
        var all = [Project(path: rootPath)]
        all.append(contentsOf: additionalProjects)
        return all
    }

    init(id: UUID = UUID(), rootPath: String, customName: String? = nil, additionalProjects: [Project] = []) {
        self.id = id
        self.rootPath = rootPath
        self.customName = customName
        self.additionalProjects = additionalProjects
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Add a project to the workspace
    mutating func addProject(_ project: Project) {
        // Don't add if it's the root or already exists
        guard project.path != rootPath,
              !additionalProjects.contains(where: { $0.path == project.path }) else { return }
        additionalProjects.append(project)
        updatedAt = Date()
    }

    /// Remove a project by ID (cannot remove root)
    mutating func removeProject(id: UUID) {
        additionalProjects.removeAll { $0.id == id }
        updatedAt = Date()
    }

    /// Rename the workspace
    mutating func rename(to newName: String?) {
        customName = newName?.isEmpty == true ? nil : newName
        updatedAt = Date()
    }

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }
}
