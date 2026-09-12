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
    var tmuxSessionName: String?
    /// ssh 호스트 별칭 (예: "arch"). 설정되면 이 워크스페이스의 tmux 서버는 그 호스트에 있고,
    /// 탭은 `ssh -t <host>`로 붙는다. nil이면 로컬 tmux.
    var remoteHost: String?

    var isRemote: Bool {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !host.isEmpty
    }

    /// 원격 호스트에서의 작업 디렉토리. 로컬 홈 아래 경로는 원격 $HOME 기준 상대경로로 옮긴다
    /// (맥 /Users/x/proj → 아치 /home/x/proj). 홈 밖 경로는 그대로 절대경로.
    var remoteDirectory: TmuxBootstrap.RemoteDirectory {
        TmuxBootstrap.remoteDirectory(forLocalPath: rootPath)
    }

    var name: String {
        customName ?? URL(fileURLWithPath: rootPath).lastPathComponent
    }

    var projects: [Project] {
        var all = [Project(path: rootPath)]
        all.append(contentsOf: additionalProjects)
        return all
    }

    /// 실제 사용할 tmux 세션명 — 커스텀 값이 있으면 그것, 없으면 이름에서 파생
    var effectiveTmuxSessionName: String {
        if let custom = tmuxSessionName,
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return TmuxBootstrap.sanitizeSessionName(name)
    }

    init(id: UUID = UUID(), rootPath: String, customName: String? = nil, additionalProjects: [Project] = [], tmuxSessionName: String? = nil, remoteHost: String? = nil) {
        self.id = id
        self.rootPath = rootPath
        self.customName = customName
        self.additionalProjects = additionalProjects
        self.tmuxSessionName = tmuxSessionName
        self.remoteHost = remoteHost
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, rootPath, customName, additionalProjects, createdAt, updatedAt, tmuxSessionName, remoteHost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        additionalProjects = try container.decodeIfPresent([Project].self, forKey: .additionalProjects) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        tmuxSessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
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
