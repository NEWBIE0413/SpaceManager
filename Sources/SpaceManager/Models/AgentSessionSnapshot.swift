import Foundation

enum AgentLaunchKind: String, Codable {
    case newSession
    case resume
    case custom
    case shell
}

struct AgentSessionSnapshot: Codable, Identifiable {
    let id: UUID
    var name: String
    var workingDirectory: String
    var lastModelId: UUID?
    var lastModelName: String?
    var lastLaunchKind: AgentLaunchKind?
    var lastLaunchCommand: String?
    var sessionTitle: String?
}

struct WorkspaceAgentState: Codable, Identifiable {
    var workspaceId: UUID
    var sessions: [AgentSessionSnapshot]
    var selectedAgentId: UUID?
    var selectedAgentGroupIndex: Int
    var selectedAgentIdsByGroup: [Int: UUID]
    var selectedProjectPath: String?
    var nextAgentIndex: Int

    var id: UUID { workspaceId }

    enum CodingKeys: String, CodingKey {
        case workspaceId
        case sessions
        case selectedAgentId
        case selectedAgentGroupIndex
        case selectedAgentIdsByGroup
        case selectedProjectPath
        case nextAgentIndex
    }

    init(
        workspaceId: UUID,
        sessions: [AgentSessionSnapshot],
        selectedAgentId: UUID?,
        selectedAgentGroupIndex: Int = 0,
        selectedAgentIdsByGroup: [Int: UUID] = [:],
        selectedProjectPath: String?,
        nextAgentIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sessions = sessions
        self.selectedAgentId = selectedAgentId
        self.selectedAgentGroupIndex = selectedAgentGroupIndex
        self.selectedAgentIdsByGroup = selectedAgentIdsByGroup
        self.selectedProjectPath = selectedProjectPath
        self.nextAgentIndex = nextAgentIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
        sessions = try container.decode([AgentSessionSnapshot].self, forKey: .sessions)
        selectedAgentId = try container.decodeIfPresent(UUID.self, forKey: .selectedAgentId)
        selectedAgentGroupIndex = try container.decodeIfPresent(Int.self, forKey: .selectedAgentGroupIndex) ?? 0
        selectedAgentIdsByGroup = try container.decodeIfPresent([Int: UUID].self, forKey: .selectedAgentIdsByGroup) ?? [:]
        selectedProjectPath = try container.decodeIfPresent(String.self, forKey: .selectedProjectPath)
        nextAgentIndex = try container.decode(Int.self, forKey: .nextAgentIndex)
    }
}
