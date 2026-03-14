import Foundation

final class PlanOrchestrator {
    private enum Tag: String {
        case be = "BE"
        case fe = "FE"
        case full = "FULL"
    }

    private var watchers: [UUID: DirectoryWatcher] = [:]
    private var planRoots: [UUID: String] = [:]
    private var lastSectionSignatures: [UUID: [String: String]] = [:]
    private var lastReportSignatures: [UUID: [String: String]] = [:]

    var sessionsProvider: ((UUID) -> [AgentSession])?

    func updateWorkspaces(_ workspaces: [Workspace]) {
        let desiredIds = Set(workspaces.map(\.id))
        let currentIds = Set(watchers.keys)

        for id in currentIds.subtracting(desiredIds) {
            watchers[id]?.stop()
            watchers[id] = nil
            planRoots[id] = nil
            lastSectionSignatures[id] = nil
            lastReportSignatures[id] = nil
        }

        for workspace in workspaces {
            let planPath = (workspace.rootPath as NSString).appendingPathComponent("plan")
            planRoots[workspace.id] = planPath
            if watchers[workspace.id] == nil {
                let watcher = DirectoryWatcher()
                watcher.onChange = { [weak self] in
                    self?.handlePlanChange(workspaceId: workspace.id)
                }
                watchers[workspace.id] = watcher
            }
            watchers[workspace.id]?.start(path: planPath)
            handlePlanChange(workspaceId: workspace.id)
        }
    }

    func stopAll() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        planRoots.removeAll()
        lastSectionSignatures.removeAll()
        lastReportSignatures.removeAll()
    }

    private func handlePlanChange(workspaceId: UUID) {
        guard let planRootPath = planRoots[workspaceId] else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processPlan(at: planRootPath, workspaceId: workspaceId)
        }
    }

    private func processPlan(at planRootPath: String, workspaceId: UUID) {
        if let promptsContent = readPrompts(at: planRootPath) {
            let blocks = parseBlocks(from: promptsContent)
            var remainingBlocks: [PromptBlock] = []
            var didModifyPrompts = false

            for block in blocks {
                guard let section = block.section else {
                    remainingBlocks.append(block)
                    continue
                }

                let payload = buildPayload(for: section)
                let signatureKey = "\(section.tag.rawValue)::\(section.title)"
                let signatureValue = payload

                var workspaceSignatures = lastSectionSignatures[workspaceId] ?? [:]
                if workspaceSignatures[signatureKey] != signatureValue {
                    workspaceSignatures[signatureKey] = signatureValue
                    lastSectionSignatures[workspaceId] = workspaceSignatures
                    let sent = send(payload, to: sessions(for: section.tag, workspaceId: workspaceId))
                    if sent {
                        didModifyPrompts = true
                        continue
                    }
                }

                remainingBlocks.append(block)
            }

            if didModifyPrompts {
                writePrompts(remainingBlocks, planRootPath: planRootPath)
            }
        }

        lastReportSignatures[workspaceId] = nil
    }

    private func readPrompts(at planRootPath: String) -> String? {
        let promptsPath = (planRootPath as NSString).appendingPathComponent("PROMPTS.md")
        guard FileManager.default.fileExists(atPath: promptsPath) else { return nil }
        return try? String(contentsOfFile: promptsPath, encoding: .utf8)
    }

    private struct Section {
        let tag: Tag
        let title: String
        let body: String
    }

    private struct PromptBlock {
        let raw: String
        let section: Section?
    }

    private func parseBlocks(from content: String) -> [PromptBlock] {
        let parts = content.components(separatedBy: "\n---")
        var blocks: [PromptBlock] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let tag = extractTag(from: trimmed) {
                let title = extractTitle(from: trimmed)
                let section = Section(tag: tag, title: title, body: trimmed)
                blocks.append(PromptBlock(raw: trimmed, section: section))
            } else {
                blocks.append(PromptBlock(raw: trimmed, section: nil))
            }
        }

        return blocks
    }

    private func extractTag(from block: String) -> Tag? {
        if block.contains("[BE]") { return .be }
        if block.contains("[FE]") { return .fe }
        if block.contains("[FULL]") { return .full }
        return nil
    }

    private func extractTitle(from block: String) -> String {
        for line in block.split(separator: "\n") {
            if line.hasPrefix("##") {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Prompt"
    }

    private func buildPayload(for section: Section) -> String {
        "[ORCHESTRATION] \(section.title)\n\n\(section.body)"
    }

    private func sessions(for tag: Tag, workspaceId: UUID) -> [AgentSession] {
        let sessions = sessionsProvider?(workspaceId) ?? []
        switch tag {
        case .be:
            return sessions.filter { matches($0, contains: ["codex"]) }
        case .fe:
            return sessions.filter { matches($0, contains: ["gemini"]) }
        case .full:
            return sessions.filter { matches($0, contains: ["codex", "gemini"]) }
        }
    }

    private func matches(_ session: AgentSession, contains needles: [String]) -> Bool {
        let name = session.displayName.lowercased()
        return needles.contains { name.contains($0) }
    }

    private func send(_ payload: String, to sessions: [AgentSession]) -> Bool {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let deliverable = sessions.filter { $0.hasLaunchedCommand && $0.isRunning }
        guard !deliverable.isEmpty else { return false }
        DispatchQueue.main.async {
            for session in deliverable {
                _ = session.getOrCreateTerminal()
                session.startTerminalIfNeeded()
                session.terminalView?.send(txt: payload + "\r")
            }
        }
        return true
    }

    private func writePrompts(_ blocks: [PromptBlock], planRootPath: String) {
        let promptsPath = (planRootPath as NSString).appendingPathComponent("PROMPTS.md")
        let content = blocks.map(\.raw).joined(separator: "\n---\n\n")
        do {
            try content.write(toFile: promptsPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to update PROMPTS.md: \(error)")
        }
    }

}
