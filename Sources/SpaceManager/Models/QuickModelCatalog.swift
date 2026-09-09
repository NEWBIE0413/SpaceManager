import Foundation
import Combine

enum QuickEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "낮음"
        case .medium: return "중간"
        case .high: return "높음"
        case .xhigh: return "매우 높음"
        case .max: return "최대"
        case .ultra: return "울트라"
        }
    }
}

struct QuickModelOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let supportedEfforts: [QuickEffort]

    var isCodex: Bool {
        id.hasPrefix("claude-codex-")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case supportedEfforts = "supported_efforts"
    }

    init(
        id: String,
        displayName: String,
        supportedEfforts: [QuickEffort] = [.low, .medium, .high, .xhigh, .max]
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedEfforts = supportedEfforts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        supportedEfforts = try container.decodeIfPresent(
            [QuickEffort].self,
            forKey: .supportedEfforts
        ) ?? [.low, .medium, .high, .xhigh, .max]
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

enum QuickComposerPreferences {
    private static let modelKey = "quickComposer.modelID"
    private static let effortKey = "quickComposer.effort"
    private static let proxyKey = "quickComposer.proxyEnabled"

    static func load(from defaults: UserDefaults = .standard) -> QuickSessionConfiguration {
        guard let modelID = defaults.string(forKey: modelKey),
              let effortRaw = defaults.string(forKey: effortKey),
              let effort = QuickEffort(rawValue: effortRaw) else {
            return .default
        }
        return QuickSessionConfiguration(
            modelID: modelID,
            effort: effort,
            proxyEnabled: defaults.bool(forKey: proxyKey)
        )
    }

    static func save(
        _ configuration: QuickSessionConfiguration,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(configuration.modelID, forKey: modelKey)
        defaults.set(configuration.effort.rawValue, forKey: effortKey)
        defaults.set(configuration.proxyEnabled, forKey: proxyKey)
    }

    static func resolved(
        _ configuration: QuickSessionConfiguration,
        availableModels: [QuickModelOption]
    ) -> QuickSessionConfiguration {
        guard let model = availableModels.first(where: { $0.id == configuration.modelID }) else {
            return .default
        }
        let effort = model.supportedEfforts.contains(configuration.effort)
            ? configuration.effort
            : (model.supportedEfforts.contains(.high) ? .high : model.supportedEfforts.first ?? .high)
        return QuickSessionConfiguration(
            modelID: model.id,
            effort: effort,
            proxyEnabled: configuration.proxyEnabled
        )
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
                let cliModels = await Task.detached(priority: .utility) {
                    ClaudeCLIModelDiscovery.discover()
                }.value
                guard !Task.isCancelled else { return }
                self?.models = cliModels.isEmpty ? Self.fallbackModels : cliModels
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

enum ClaudeCLIModelDiscovery {
    private static let lock = NSLock()
    private static var cached: (path: String, stringsPath: String, signature: FileSignature, models: [QuickModelOption])?

    static func discover(executablePath: String? = nil, stringsPath: String = "/usr/bin/strings") -> [QuickModelOption] {
        let candidate = executablePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path
        let executable = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
        // Multiple quick windows share discovery; a CLI upgrade invalidates it.
        return lock.withLock {
            guard let signature = FileSignature.read(executable),
                  FileManager.default.isExecutableFile(atPath: stringsPath) else { return [] }
            if let cached, cached.path == executable.path, cached.stringsPath == stringsPath,
               cached.signature == signature { return cached.models }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: stringsPath)
            process.arguments = ["-a", executable.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                var parser = StringTableParser()
                while let data = try pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    parser.consume(data)
                }
                parser.finish()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                cached = (executable.path, stringsPath, signature, parser.models)
                return parser.models
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                return []
            }
        }
    }

    static func parseStringTable(_ output: String) -> [QuickModelOption] {
        var parser = StringTableParser()
        parser.consume(Data(output.utf8))
        parser.finish()
        return parser.models
    }

    /// Retain only the adjacent candidate lines, not the CLI's entire string table.
    private struct StringTableParser {
        private var partial = Data()
        private var skipping = false
        private var previous: String?
        private var seen = Set<String>()
        private(set) var models: [QuickModelOption] = []

        mutating func consume(_ data: Data) {
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 10) ?? data.endIndex
                if !skipping {
                    if partial.count + end - start <= 4096 { partial.append(data[start..<end]) }
                    else { partial.removeAll(keepingCapacity: true); skipping = true; previous = nil }
                }
                if end < data.endIndex { finish(); start = end + 1 }
                else { break }
            }
        }

        mutating func finish() {
            if !skipping, let raw = String(data: partial, encoding: .utf8), !raw.isEmpty {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let previous, let model = parsePair(idLine: previous, displayLine: line), seen.insert(model.id).inserted {
                    models.append(model)
                }
                previous = line
            }
            partial.removeAll(keepingCapacity: true)
            skipping = false
        }
    }

    private static func parsePair(idLine: String, displayLine: String) -> QuickModelOption? {
        let pieces = idLine.split(separator: "-").map(String.init)
        let families: Set<String> = ["fable", "mythos", "opus", "sonnet", "haiku"]
        guard pieces.count >= 3,
              pieces[0] == "claude",
              families.contains(pieces[1]),
              pieces.dropFirst(2).allSatisfy({ Int($0) != nil }) else { return nil }
        let expectedDisplay = "Claude \(pieces[1].capitalized) "
            + pieces.dropFirst(2).joined(separator: ".")
        guard displayLine == expectedDisplay else { return nil }
        return QuickModelOption(id: idLine, displayName: displayLine)
    }
}
