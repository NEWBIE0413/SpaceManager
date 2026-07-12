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

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Represents a workspace containing multiple projects
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var rootPath: String
    var customName: String?
    var additionalProjects: [Project]
    var createdAt: Date
    var updatedAt: Date

    var name: String {
        customName ?? URL(fileURLWithPath: rootPath).lastPathComponent
    }

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

    enum CodingKeys: String, CodingKey {
        case id, rootPath, customName, additionalProjects, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        additionalProjects = try container.decodeIfPresent([Project].self, forKey: .additionalProjects) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    mutating func addProject(_ project: Project) {
        guard project.path != rootPath,
              !additionalProjects.contains(where: { $0.path == project.path }) else { return }
        additionalProjects.append(project)
        updatedAt = Date()
    }

    mutating func removeProject(id: UUID) {
        additionalProjects.removeAll { $0.id == id }
        updatedAt = Date()
    }

    mutating func rename(to newName: String?) {
        customName = newName?.isEmpty == true ? nil : newName
        updatedAt = Date()
    }

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }
}
