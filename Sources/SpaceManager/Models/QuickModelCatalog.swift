import Foundation
import Combine

enum QuickEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "낮음"
        case .medium: return "중간"
        case .high: return "높음"
        case .xhigh: return "매우 높음"
        case .max: return "최대"
        }
    }
}

struct QuickModelOption: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String

    var isCodex: Bool {
        id.hasPrefix("claude-codex-")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct QuickSessionConfiguration: Equatable {
    let modelID: String
    let effort: QuickEffort
    let proxyEnabled: Bool

    static let `default` = QuickSessionConfiguration(
        modelID: "claude-sonnet-5",
        effort: .high,
        proxyEnabled: false
    )

    var usesProxy: Bool {
        proxyEnabled || modelID.hasPrefix("claude-codex-")
    }
}

@MainActor
final class QuickModelCatalog: ObservableObject {
    static let fallbackModels: [QuickModelOption] = [
        QuickModelOption(id: "claude-opus-4-8", displayName: "Opus 4.8"),
        QuickModelOption(id: "claude-sonnet-5", displayName: "Sonnet 5"),
        QuickModelOption(id: "claude-fable-5", displayName: "Fable 5"),
        QuickModelOption(id: "claude-haiku-4-5", displayName: "Haiku 4.5"),
    ]

    @Published private(set) var models: [QuickModelOption]
    @Published private(set) var routerAvailable = false
    @Published private(set) var isLoading = false

    private let endpoint: URL
    private var refreshTask: Task<Void, Never>?

    init(endpoint: URL = URL(string: "http://127.0.0.1:4141/v1/models?limit=1000")!) {
        self.endpoint = endpoint
        models = Self.fallbackModels
    }

    deinit {
        refreshTask?.cancel()
    }

    func refresh() {
        refreshTask?.cancel()
        isLoading = true
        let endpoint = endpoint
        refreshTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: endpoint)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let discovered = try Self.decodeModels(data)
                guard !discovered.isEmpty else {
                    throw URLError(.cannotParseResponse)
                }
                guard !Task.isCancelled else { return }
                self?.models = discovered
                self?.routerAvailable = true
            } catch {
                guard !Task.isCancelled else { return }
                self?.models = Self.fallbackModels
                self?.routerAvailable = false
            }
            self?.isLoading = false
        }
    }

    nonisolated static func decodeModels(_ data: Data) throws -> [QuickModelOption] {
        struct Response: Decodable {
            let data: [QuickModelOption]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var seen: Set<String> = []
        return decoded.data.filter { option in
            option.id.hasPrefix("claude-") && seen.insert(option.id).inserted
        }
    }
}
